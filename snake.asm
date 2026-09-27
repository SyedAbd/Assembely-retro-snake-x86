; Snake for the IBM PC / 8088, single file, NASM -> DOS .COM (tested in
; DOSBox). 80x25 text mode, row 0 is a status line, rows 1-24 are the
; playfield. Body segments are a blank space on a colored background; the
; head shows a direction arrow; food is a letter on a different colored
; background. Off one edge wraps to the opposite edge on the same row/
; column. Speed ramps up gradually the longer you survive.
;
; No BIOS keyboard (INT 16h) or clock (INT 1Ah) calls during play: input
; comes from hooking IRQ1 (INT 09h) and reading raw scan codes off port
; 60h, and timing runs off our own counter driven by hooking IRQ0 (INT
; 08h), chained to the original handler so the system clock still works.
; Both vectors are restored before exit. Video mode is set once via BIOS;
; everything else writes straight to B800h video memory.
;
; Build:   nasm -f bin -o snake.com snake.asm
; Run:     dosbox snake.com

BITS 16
org 0x100

VIDSEG        equ 0xB800
COLS          equ 80
ROWS          equ 24
TOP_ROW       equ 1
MAXCELLS      equ COLS*ROWS
SNAKE_BODY_ATTR equ 0x20          ; green bg, blank body segments
HEAD_ATTR       equ 0x2F          ; green bg, white arrow
FOOD_CHAR       equ 'F'
FOOD_ATTR       equ 0x4E          ; red bg, yellow letter
START_LEN       equ 3

MOVE_DELAY_START equ 3            ; our ticks between moves at game start (~18.2/sec)
MOVE_DELAY_MIN   equ 1
RAMP_INTERVAL    equ 150          ; our ticks between speed-ups (~8 sec)

DIR_RIGHT   equ 0
DIR_LEFT    equ 1
DIR_UP      equ 2
DIR_DOWN    equ 3

start:
    mov     ax, 0x0003
    int     0x10
    mov     ah, 0x01
    mov     cx, 0x2000
    int     0x10

    call    install_handlers    ; clobbers es (INT21h AH=35h returns via es:bx)
    mov     ax, VIDSEG
    mov     es, ax

    call    seed_rng_from_pit
    call    clear_playfield
    call    draw_border_labels
    call    init_snake
    call    spawn_food
    call    draw_score

    mov     ax, [ourTick]
    mov     [lastMoveTick], ax
    mov     [rampBaseTick], ax

.loop:
    cmp     byte [wantExit], 1
    je      quit_ok

    mov     ax, [ourTick]
    sub     ax, [rampBaseTick]
    cmp     ax, RAMP_INTERVAL
    jb      .checkmove
    mov     ax, [ourTick]
    mov     [rampBaseTick], ax
    cmp     word [curMoveDelay], MOVE_DELAY_MIN
    jbe     .checkmove
    dec     word [curMoveDelay]

.checkmove:
    mov     ax, [ourTick]
    sub     ax, [lastMoveTick]
    cmp     ax, [curMoveDelay]
    jb      .loop

    mov     ax, [ourTick]
    mov     [lastMoveTick], ax
    call    move_snake
    cmp     byte [dead], 1
    je      game_over
    jmp     .loop

quit_ok:
    call    restore_handlers
    mov     ax, 0x0003
    int     0x10
    mov     ax, 0x4c00
    int     0x21

install_handlers:
    mov     ah, 0x35
    mov     al, 0x08
    int     0x21
    mov     [oldTimerOff], bx
    mov     [oldTimerSeg], es

    mov     ah, 0x35
    mov     al, 0x09
    int     0x21
    mov     [oldKbdOff], bx
    mov     [oldKbdSeg], es

    cli
    push    ds
    mov     ax, cs
    mov     ds, ax
    mov     dx, timer_isr
    mov     ah, 0x25
    mov     al, 0x08
    int     0x21
    mov     dx, kbd_isr
    mov     ah, 0x25
    mov     al, 0x09
    int     0x21
    pop     ds
    sti
    ret

; must read all four saved values before switching ds, or the second
; restore reads through the wrong segment
restore_handlers:
    push    ds
    mov     dx, [oldTimerOff]
    mov     bx, [oldTimerSeg]
    mov     cx, [oldKbdOff]
    mov     si, [oldKbdSeg]

    cli
    mov     ax, bx
    mov     ds, ax
    mov     ah, 0x25
    mov     al, 0x08
    int     0x21

    mov     dx, cx
    mov     ax, si
    mov     ds, ax
    mov     ah, 0x25
    mov     al, 0x09
    int     0x21
    sti
    pop     ds
    ret

; chains to the previous INT 08h handler so BIOS/DOS timing keeps working
timer_isr:
    push    ax
    push    ds
    mov     ax, cs
    mov     ds, ax
    inc     word [ourTick]
    pop     ds
    pop     ax
    pushf
    call    far [cs:oldTimerOff]   ; oldTimerOff:oldTimerSeg = far ptr
    iret

; fully replaces the BIOS keyboard handler; owns its own EOI
kbd_isr:
    push    ax
    push    bx
    push    ds
    mov     ax, cs
    mov     ds, ax

    in      al, 0x60
    cmp     al, 0xE0
    jne     .notE0
    mov     byte [extFlag], 1
    jmp     .eoi
.notE0:
    test    al, 0x80
    jnz     .clearext           ; release code, ignore
    mov     byte [anyKeyFlag], 1
    cmp     al, 0x01            ; Esc
    jne     .checkarrows
    mov     byte [wantExit], 1
    jmp     .clearext
.checkarrows:
    cmp     al, 0x48
    je      .up
    cmp     al, 0x50
    je      .down
    cmp     al, 0x4b
    je      .left
    cmp     al, 0x4d
    je      .right
    jmp     .clearext
.up:
    mov     bl, DIR_UP
    jmp     .apply
.down:
    mov     bl, DIR_DOWN
    jmp     .apply
.left:
    mov     bl, DIR_LEFT
    jmp     .apply
.right:
    mov     bl, DIR_RIGHT
.apply:
    mov     bh, [direction]
    xor     bh, 1
    cmp     bl, bh              ; reject direct reversal
    je      .clearext
    mov     [pendingDir], bl
.clearext:
    mov     byte [extFlag], 0
.eoi:
    mov     al, 0x20
    out     0x20, al
    pop     ds
    pop     bx
    pop     ax
    iret

seed_rng_from_pit:
    push    ax
    push    bx
    mov     al, 0x00
    out     0x43, al
    in      al, 0x40
    mov     bl, al
    in      al, 0x40
    mov     bh, al
    mov     [rngSeed], bx
    pop     bx
    pop     ax
    ret

; fills the playfield with blanks at attribute 0, the marker spawn_food and
; move_snake use to recognize an empty cell
clear_playfield:
    xor     cx, cx
.rowloop:
    xor     dx, dx
.colloop:
    mov     al, cl
    mov     ah, dl
    call    calc_offset
    mov     byte [es:di], ' '
    mov     byte [es:di+1], 0
    inc     dl
    cmp     dl, COLS
    jne     .colloop
    inc     cl
    cmp     cl, ROWS
    jne     .rowloop
    ret

init_snake:
    mov     word [headPtr], 0
    mov     word [tailPtr], 0
    mov     word [snakeLen], 0
    mov     byte [direction], DIR_RIGHT
    mov     byte [pendingDir], DIR_RIGHT
    mov     word [score], 0
    mov     byte [dead], 0
    mov     byte [wantExit], 0
    mov     word [curMoveDelay], MOVE_DELAY_START

    mov     cl, ROWS/2
    mov     ch, COLS/2
    sub     ch, START_LEN-1

    mov     bx, 0
.seg:
    mov     [snakeRow+bx], cl
    mov     [snakeCol+bx], ch
    push    ax
    mov     al, cl
    mov     ah, ch
    call    calc_offset
    cmp     bx, START_LEN-1
    jne     .bodycell
    call    draw_head_char
    jmp     .cellDone
.bodycell:
    mov     byte [es:di], ' '
    mov     byte [es:di+1], SNAKE_BODY_ATTR
.cellDone:
    pop     ax
    inc     ch
    inc     bx
    cmp     bx, START_LEN
    jne     .seg

    mov     word [headPtr], START_LEN-1
    mov     word [tailPtr], 0
    mov     word [snakeLen], START_LEN
    ret

move_snake:
    mov     al, [pendingDir]
    mov     [direction], al

    mov     bx, [headPtr]
    mov     al, [snakeRow+bx]
    mov     ah, [snakeCol+bx]
    call    step_head           ; -> al=newRow, ah=newCol

    push    ax
    call    calc_offset
    mov     al, [es:di+1]       ; occupancy lives in the attribute now, not
    and     al, 0xF0            ; the character (body cells are just spaces)
    cmp     al, SNAKE_BODY_ATTR ; head/body share this bg color
    je      .hit_self
    cmp     al, FOOD_ATTR & 0xF0
    je      .ate_food
    pop     ax
    call    advance_head
    jmp     .drawn

.ate_food:
    pop     ax
    call    advance_head_grow
    inc     word [score]
    call    draw_score
    call    spawn_food
    jmp     .drawn

.hit_self:
    pop     ax
    mov     byte [dead], 1
    ret

.drawn:
    ret

step_head:
    mov     dl, [direction]
    cmp     dl, DIR_RIGHT
    je      .right
    cmp     dl, DIR_LEFT
    je      .left
    cmp     dl, DIR_UP
    je      .up
    jmp     .down
.right:
    inc     ah
    cmp     ah, COLS
    jne     .done
    mov     ah, 0
    jmp     .done
.left:
    cmp     ah, 0
    jne     .l2
    mov     ah, COLS-1
    jmp     .done
.l2:
    dec     ah
    jmp     .done
.up:
    cmp     al, 0
    jne     .u2
    mov     al, ROWS-1
    jmp     .done
.u2:
    dec     al
    jmp     .done
.down:
    inc     al
    cmp     al, ROWS
    jne     .done
    mov     al, 0
.done:
    ret

; draws headChars[direction] + HEAD_ATTR at es:di (di already set by caller)
draw_head_char:
    push    ax
    push    si
    xor     ax, ax
    mov     al, [direction]
    mov     si, ax
    mov     al, [headChars+si]
    mov     byte [es:di], al
    mov     byte [es:di+1], HEAD_ATTR
    pop     si
    pop     ax
    ret

; input al=newRow, ah=newCol. Old head becomes a body segment, new head is
; drawn with the arrow, tail is erased (length stays the same).
advance_head:
    push    ax
    mov     bx, [headPtr]
    mov     al, [snakeRow+bx]
    mov     ah, [snakeCol+bx]
    call    calc_offset
    mov     byte [es:di], ' '
    mov     byte [es:di+1], SNAKE_BODY_ATTR

    pop     ax
    mov     bx, [headPtr]
    inc     bx
    cmp     bx, MAXCELLS
    jne     .h1
    mov     bx, 0
.h1:
    mov     [headPtr], bx
    mov     [snakeRow+bx], al
    mov     [snakeCol+bx], ah
    call    calc_offset
    call    draw_head_char

    mov     bx, [tailPtr]
    mov     al, [snakeRow+bx]
    mov     ah, [snakeCol+bx]
    call    calc_offset
    mov     byte [es:di], ' '
    mov     byte [es:di+1], 0
    inc     bx
    cmp     bx, MAXCELLS
    jne     .t1
    mov     bx, 0
.t1:
    mov     [tailPtr], bx
    ret

; same as advance_head but keeps the tail (snake grows)
advance_head_grow:
    push    ax
    mov     bx, [headPtr]
    mov     al, [snakeRow+bx]
    mov     ah, [snakeCol+bx]
    call    calc_offset
    mov     byte [es:di], ' '
    mov     byte [es:di+1], SNAKE_BODY_ATTR

    pop     ax
    mov     bx, [headPtr]
    inc     bx
    cmp     bx, MAXCELLS
    jne     .h1
    mov     bx, 0
.h1:
    mov     [headPtr], bx
    mov     [snakeRow+bx], al
    mov     [snakeCol+bx], ah
    call    calc_offset
    call    draw_head_char
    inc     word [snakeLen]
    ret

; input al=row, ah=col. output di=byte offset into es (B800h) for that cell.
calc_offset:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     bh, 0
    mov     bl, ah              ; mul below clobbers dx, so col can't live there
    xor     ah, ah
    add     ax, TOP_ROW
    mov     cx, COLS
    mul     cx
    add     ax, bx
    shl     ax, 1
    mov     di, ax
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; random free cell, with a bounded linear-scan fallback so it always
; terminates as long as one free cell exists
spawn_food:
    mov     cx, 200
.try:
    push    cx
    mov     cx, ROWS
    call    rand_mod
    mov     [tmpRow], al
    mov     cx, COLS
    call    rand_mod
    mov     [tmpCol], al
    mov     al, [tmpRow]
    mov     ah, [tmpCol]
    call    calc_offset
    mov     al, [es:di+1]
    pop     cx
    cmp     al, 0
    je      .found
    loop    .try

    mov     cx, MAXCELLS
    call    rand_mod
    mov     [scanIdx], ax
    mov     cx, MAXCELLS
.scan:
    mov     ax, [scanIdx]
    mov     bl, COLS
    div     bl                  ; al=row, ah=col
    mov     [tmpRow], al
    mov     [tmpCol], ah
    push    cx
    mov     al, [tmpRow]
    mov     ah, [tmpCol]
    call    calc_offset
    mov     al, [es:di+1]
    pop     cx
    cmp     al, 0
    je      .found
    inc     word [scanIdx]
    cmp     word [scanIdx], MAXCELLS
    jne     .s1
    mov     word [scanIdx], 0
.s1:
    loop    .scan
    ret                         ; board full; leave food unplaced

.found:
    mov     al, [tmpRow]
    mov     ah, [tmpCol]
    call    calc_offset
    mov     byte [es:di], FOOD_CHAR
    mov     byte [es:di+1], FOOD_ATTR
    ret

get_random:
    push    bx
    push    dx
    mov     ax, [rngSeed]
    mov     bx, 25173
    mul     bx
    add     ax, 13849
    mov     [rngSeed], ax
    pop     dx
    pop     bx
    ret

rand_mod:
    push    cx
    call    get_random
    pop     cx
    xor     dx, dx
    div     cx
    mov     ax, dx
    ret

draw_border_labels:
    mov     di, 0
    mov     si, titleMsg
    mov     bl, 0x0f
    call    print_at
    ret

draw_score:
    mov     di, (COLS-16)*2
    mov     si, scoreLabel
    mov     bl, 0x0f
    call    print_at
    mov     ax, [score]
    mov     di, (COLS-16+7)*2
    call    print_number
    ret

print_at:
.next:
    mov     al, [si]
    cmp     al, 0
    je      .done
    mov     [es:di], al
    mov     [es:di+1], bl
    inc     si
    add     di, 2
    jmp     .next
.done:
    ret

; writes ax as decimal (no leading zeros) at es:di, attribute 0x0f
print_number:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     bx, 10
    xor     cx, cx
    cmp     ax, 0
    jne     .split
    mov     byte [numBuf], '0'
    mov     byte [numBuf+1], '$'
    jmp     .print
.split:
.divloop:
    xor     dx, dx
    div     bx
    add     dl, '0'
    push    dx
    inc     cx
    cmp     ax, 0
    jne     .divloop
    mov     si, numBuf
.popd:
    pop     dx
    mov     [si], dl
    inc     si
    loop    .popd
    mov     byte [si], '$'
.print:
    mov     si, numBuf
    mov     bl, 0x0f
.pnext:
    mov     al, [si]
    cmp     al, '$'
    je      .pdone
    mov     [es:di], al
    mov     [es:di+1], bl
    inc     si
    add     di, 2
    jmp     .pnext
.pdone:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

game_over:
    mov     di, (12*COLS+34)*2
    mov     si, gameOverMsg
    mov     bl, 0x4f
    call    print_at

    mov     di, (14*COLS+34)*2
    mov     si, finalScoreMsg
    mov     bl, 0x4f
    call    print_at
    mov     ax, [score]
    mov     di, (14*COLS+34+13)*2
    call    print_number

    mov     byte [anyKeyFlag], 0
.wait:
    cmp     byte [anyKeyFlag], 1
    jne     .wait
    jmp     quit_ok

titleMsg:       db 'SNAKE - arrows to move, Esc to quit', 0
scoreLabel:     db 'Score: ', 0
gameOverMsg:    db 'GAME OVER', 0
finalScoreMsg:  db 'Final score: ', 0
headChars:      db '>', '<', '^', 'v'   ; indexed by DIR_RIGHT/LEFT/UP/DOWN

oldTimerOff: dw 0    ; must stay adjacent (used together as a far pointer)
oldTimerSeg: dw 0
oldKbdOff:   dw 0
oldKbdSeg:   dw 0

ourTick:      dw 0
lastMoveTick: dw 0
rampBaseTick: dw 0
curMoveDelay: dw MOVE_DELAY_START

rngSeed:    dw 0
headPtr:    dw 0
tailPtr:    dw 0
snakeLen:   dw 0
score:      dw 0
scanIdx:    dw 0
direction:  db 0
pendingDir: db 0
dead:       db 0
wantExit:   db 0
extFlag:    db 0
anyKeyFlag: db 0
tmpRow:     db 0
tmpCol:     db 0
numBuf:     times 8 db 0

snakeRow:   times MAXCELLS db 0
snakeCol:   times MAXCELLS db 0
