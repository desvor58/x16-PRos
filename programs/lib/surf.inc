; ========================================================================
; surf.inc - drawing surface that works full-screen or inside a GUI window
; Copyright (C) 2026 PRoX2011
;
; Depends on grafx.inc.
; ========================================================================

%ifndef SURF_INC
%define SURF_INC

surf_windowed db 0
surf_close    db 0
surf_dirty    db 0
surf_ox       dw 0
surf_oy       dw 0
surf_w        dw 640
surf_h        dw 480
surf_cl       dw 0
surf_ct       dw 0
surf_cr       dw 639
surf_cb       dw 479

; ========================================================================
; surf_sync - query the WM for this task's window and update the surface
; IN:  nothing
; OUT: [surf_windowed] = 1 if hosted in a window, else 0
;      [surf_close]    = 1 if the WM asked us to close
;      [surf_dirty]    = 1 if the WM wants a repaint this frame
;      surface origin/size in [surf_ox]/[surf_oy]/[surf_w]/[surf_h]
;
; NOTE: Recomended to call once per frame.
; ========================================================================
surf_sync:
    pusha
    mov ah, 0x31
    int 0x23
    test al, 0x01
    jz .fullscreen
    mov byte [surf_windowed], 1
    test al, 0x02
    jz .nclose
    mov byte [surf_close], 1
.nclose:
    mov byte [surf_dirty], 0
    test al, 0x04
    jz .ndirty
    mov byte [surf_dirty], 1
.ndirty:
    mov [surf_ox], cx
    mov [surf_oy], dx
    mov [surf_w], si
    mov [surf_h], di
    jmp .clip
.fullscreen:
    mov byte [surf_windowed], 0
    mov word [surf_ox], 0
    mov word [surf_oy], 0
    mov word [surf_w], 640
    mov word [surf_h], 480
.clip:
    mov ax, [surf_ox]
    mov [surf_cl], ax
    add ax, [surf_w]
    dec ax
    mov [surf_cr], ax
    mov ax, [surf_oy]
    mov [surf_ct], ax
    add ax, [surf_h]
    dec ax
    mov [surf_cb], ax
    popa
    ret

; ========================================================================
; surf_clear - fill the whole surface with colour
; IN:  AL = colour (0..15)
; OUT: nothing (all registers preserved)
; ========================================================================
surf_clear:
    pusha
    cmp byte [surf_windowed], 0
    jne .win
    call surf_fs_clear
    popa
    ret
.win:
    mov cx, [surf_ox]
    mov dx, [surf_oy]
    mov si, [surf_w]
    mov di, [surf_h]
    call gfx_fill_rect
    popa
    ret

; ========================================================================
; surf_fs_clear - fill the whole 640x480 screen with colour AL
; IN:  AL = colour (0..15)
; OUT: nothing (all registers preserved)
; ========================================================================
surf_fs_clear:
    pusha
    push es
    and al, 0x0F
    mov bl, al
    mov dx, 0x3CE
    mov al, 0
    out dx, al
    inc dx
    mov al, bl
    out dx, al
    mov dx, 0x3CE
    mov al, 1
    out dx, al
    inc dx
    mov al, 0x0F
    out dx, al
    mov dx, 0x3CE
    mov al, 3
    out dx, al
    inc dx
    xor al, al
    out dx, al
    mov dx, 0x3CE
    mov al, 8
    out dx, al
    inc dx
    mov al, 0xFF
    out dx, al
    mov dx, 0x3C4
    mov al, 2
    out dx, al
    inc dx
    mov al, 0x0F
    out dx, al
    mov ax, 0xA000
    mov es, ax
    xor di, di
    mov cx, 19200
    xor ax, ax
    cld
    rep stosw
    mov dx, 0x3CE
    mov al, 1
    out dx, al
    inc dx
    xor al, al
    out dx, al
    pop es
    popa
    ret

; ========================================================================
; surf_hline - horizontal span in surface-relative coords, clipped
; IN:  CX = x1
;      BX = x2
;      DX = y
;      AL = colour (0..15)
; OUT: nothing (all registers preserved)
; ========================================================================
surf_hline:
    pusha
    mov [.col], al
    mov ax, dx
    add ax, [surf_oy]
    cmp ax, [surf_ct]
    jl .skip
    cmp ax, [surf_cb]
    jg .skip
    mov [.y], ax
    mov ax, cx
    add ax, [surf_ox]
    mov [.x1], ax
    mov ax, bx
    add ax, [surf_ox]
    mov [.x2], ax
    mov ax, [.x1]
    mov bx, [.x2]
    cmp ax, bx
    jle .ord
    xchg ax, bx
.ord:
    cmp ax, [surf_cl]
    jge .lok
    mov ax, [surf_cl]
.lok:
    cmp bx, [surf_cr]
    jle .rok
    mov bx, [surf_cr]
.rok:
    cmp ax, bx
    jg .skip
    mov cx, ax
    mov dx, [.y]
    mov al, [.col]
    call gfx_hline
.skip:
    popa
    ret
.col db 0
.x1  dw 0
.x2  dw 0
.y   dw 0

; ========================================================================
; surf_pixel - plot a pixel in surface-relative coords, clipped
; IN:  CX = x
;      DX = y
;      AL = colour (0..15)
; OUT: nothing (all registers preserved)
; ========================================================================
surf_pixel:
    pusha
    mov bx, cx
    call surf_hline
    popa
    ret

; ========================================================================
; surf_fill_rect - filled rectangle in surface-relative coords, clipped
; IN:  CX = x
;      DX = y
;      SI = width
;      DI = height
;      AL = colour (0..15)
; OUT: nothing (all registers preserved)
; ========================================================================
surf_fill_rect:
    pusha
    mov [.col], al
    mov [.rx], cx
    mov ax, cx
    add ax, si
    dec ax
    mov [.rx2], ax
    mov [.ry], dx
    mov [.rows], di
.row:
    cmp word [.rows], 0
    jle .done
    mov al, [.col]
    mov cx, [.rx]
    mov bx, [.rx2]
    mov dx, [.ry]
    call surf_hline
    inc word [.ry]
    dec word [.rows]
    jmp .row
.done:
    popa
    ret
.col  db 0
.rx   dw 0
.rx2  dw 0
.ry   dw 0
.rows dw 0

; ========================================================================
; surf_fill_circle - filled circle in surface-relative coords, clipped
; IN:  CX = centre x
;      DX = centre y
;      BX = radius
;      AL = colour (0..15)
; OUT: nothing (all registers preserved)
; ========================================================================
surf_fill_circle:
    pusha
    mov [.col], al
    mov [.cx], cx
    mov [.cy], dx
    mov word [.x], 0
    mov [.y], bx
    mov ax, 1
    sub ax, bx
    mov [.d], ax
.loop:
    mov ax, [.x]
    cmp ax, [.y]
    jg .done
    call .spans
    mov ax, [.d]
    test ax, ax
    js .dneg
    mov ax, [.x]
    sub ax, [.y]
    add ax, ax
    add ax, 5
    add [.d], ax
    dec word [.y]
    jmp .incx
.dneg:
    mov ax, [.x]
    add ax, ax
    add ax, 3
    add [.d], ax
.incx:
    inc word [.x]
    jmp .loop
.done:
    popa
    ret
.spans:
    mov al, [.col]
    mov cx, [.cx]
    sub cx, [.x]
    mov bx, [.cx]
    add bx, [.x]
    mov dx, [.cy]
    add dx, [.y]
    call surf_hline
    mov al, [.col]
    mov cx, [.cx]
    sub cx, [.x]
    mov bx, [.cx]
    add bx, [.x]
    mov dx, [.cy]
    sub dx, [.y]
    call surf_hline
    mov al, [.col]
    mov cx, [.cx]
    sub cx, [.y]
    mov bx, [.cx]
    add bx, [.y]
    mov dx, [.cy]
    add dx, [.x]
    call surf_hline
    mov al, [.col]
    mov cx, [.cx]
    sub cx, [.y]
    mov bx, [.cx]
    add bx, [.y]
    mov dx, [.cy]
    sub dx, [.x]
    call surf_hline
    ret
.col db 0
.cx  dw 0
.cy  dw 0
.x   dw 0
.y   dw 0
.d   dw 0

; ========================================================================
; surf_print - draw a NUL-terminated string
; IN:  CX = x (top-left, surface-relative)
;      DX = y
;      SI = string pointer
;      AL = colour (0..15)
; OUT: nothing (all registers preserved)
; ========================================================================
surf_print:
    pusha
    call surf_font_get
    mov [.color], al
    mov [.penx], cx
    mov [.peny], dx
    mov [.sptr], si
.ch:
    mov si, [.sptr]
    mov al, [si]
    test al, al
    jz .done
    inc si
    mov [.sptr], si
    cmp al, ' '
    je .advance
    xor ah, ah
    shl ax, 4
    add ax, [surf_font_off]
    mov [.gptr], ax
    mov word [.r], 0
.row:
    cmp word [.r], 16
    jae .advance
    push es
    mov es, [surf_font_seg]
    mov bx, [.gptr]
    add bx, [.r]
    mov al, [es:bx]
    pop es
    mov [.gbyte], al
    mov word [.c], 0
.col:
    cmp word [.c], 8
    jae .nextrow
    mov cl, [.c]
    mov ah, 0x80
    shr ah, cl
    test [.gbyte], ah
    jz .nextcol
    mov cx, [.penx]
    add cx, [.c]
    mov dx, [.peny]
    add dx, [.r]
    mov al, [.color]
    call surf_pixel
.nextcol:
    inc word [.c]
    jmp .col
.nextrow:
    inc word [.r]
    jmp .row
.advance:
    add word [.penx], 8
    jmp .ch
.done:
    popa
    ret
.color db 0
.penx  dw 0
.peny  dw 0
.sptr  dw 0
.gptr  dw 0
.gbyte db 0
.r     dw 0
.c     dw 0

; ========================================================================
; surf_font_get - resolve the active 8x16 font once and cache it
; IN:  nothing
; OUT: [surf_font_seg]:[surf_font_off] -> font bitmap
; ========================================================================
surf_font_get:
    cmp byte [surf_font_ready], 0
    jne .ret
    pusha
    push es
    xor ax, ax
    mov es, ax
    mov bp, [es:0x43*4]
    mov ax, [es:0x43*4 + 2]
    mov cx, ax
    or cx, bp
    jnz .have
    mov ax, 0x1130
    mov bh, 0x06
    int 0x10
    mov ax, es
.have:
    mov [surf_font_seg], ax
    mov [surf_font_off], bp
    pop es
    popa
    mov byte [surf_font_ready], 1
.ret:
    ret

surf_font_seg   dw 0
surf_font_off   dw 0
surf_font_ready db 0

%endif ; SURF_INC