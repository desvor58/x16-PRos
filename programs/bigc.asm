; ==================================================================
; x16-PRos -- BIGC.BIN. Big calculator.
; Copyright (C) 2025 Desvor, PRoX2011
;
; Made by Desvor
; =================================================================

[BITS 16]
[ORG 0x8000]

start:
    mov ah, 0x05
    int 0x21

    mov ah, 0x01
    mov si, welcome_msg
    int 0x21

main_loop:
    mov ah, 0x01
    mov si, prompt
    int 0x21

    call read_input

    call infix_to_postfix

    mov ah, 0x05
    int 0x21

    mov si, postfix_buffer
    mov bx, 0x0F
    mov ah, 0x01
    int 0x21

exit:
    ret


read_input:
    pusha

    mov di, input_buffer
    xor cx, cx
.read_loop:
    mov ah, 0
    int 0x16

    cmp al, 0x1B
    jz exit
    cmp al, 0x08
    jz .backspace
    cmp al, 0x0D
    jz .done

    cmp al, '-'
    jz .valid_char
    cmp al, '+'
    jz .valid_char
    cmp al, '*'
    jz .valid_char
    cmp al, '/'
    jz .valid_char
    cmp al, '('
    jz .valid_char
    cmp al, ')'
    jz .valid_char
    cmp al, '0'
    jb .read_loop
    cmp al, '9'
    ja .read_loop

.valid_char:
    mov ah, 0x0E
    mov bx, 0x0F
    int 0x10

    stosb
    inc cx

    cmp cx, 64
    jae .done

    jmp .read_loop

.done:
    xor al, al
    stosb
    popa
    ret

.backspace:
    test cx, cx
    jz .read_loop
    dec di
    dec cx
    mov ax, 0x0E08
    mov bx, 0x0F
    int 0x10
    mov al, ' '
    int 0x10
    mov al, 0x08
    int 0x10
    jmp .read_loop


infix_to_postfix:
    pusha

    mov ax, ds
    mov es, ax
    mov si, input_buffer
    mov di, postfix_buffer
    mov word [op_stack_top], 0
.parse_loop:
    lodsb

    test al, al
    jz .done

    call try_get_digit
    call try_get_lparent
    call try_get_rparent
    call try_get_operator

    jmp .parse_loop

.done:
.ops_pull_loop:
    mov bx, [op_stack_top]
    pusha
        mov ax, bx
        call string_int_to_string
        mov si, ax
        mov ah, 0x01
        int 0x21
    popa
    test bx, bx
    jz .exit
    mov al, [op_stack + bx]
    stosb
    dec word [op_stack_top]
    jmp .ops_pull_loop

.exit:
    popa
    ret


try_get_digit:
    cmp al, '0'
    jb .exit
    cmp al, '9'
    ja .exit

.get_loop:
    stosb
    lodsb

    jmp try_get_digit

.exit:
    push ax
        mov al, ' '
        stosb
    pop ax
    ret


try_get_lparent:
    cmp al, '('
    jnz .exit
    mov bx, [op_stack_top]
    mov byte [op_stack + bx], LPARENT_TOK
    inc word [op_stack_top]
.exit:
    ret


try_get_rparent:
    cmp al, ')'
    jnz .exit

.pull_ops_loop:
    mov bx, [op_stack_top]
    test bx, bx
    jz .exit
    mov al, [op_stack + bx]
    cmp al, LPARENT_TOK
    jz .exit

    stosb
    dec word [op_stack_top]
    jmp .pull_ops_loop

.exit:
    mov bx, [op_stack_top]
    test bx, bx
    jz .end
    mov al, [op_stack + bx]
    cmp al, LPARENT_TOK
    jz .remove_lparent
.end:
    ret

.remove_lparent:
    dec word [op_stack_top]
    ret


try_get_operator:
    push ax
    call get_op_priority
    test bl, bl
    jz .exit

    mov bh, bl

.pull_ops_loop:
    mov bp, [op_stack_top]
    test bp, bp
    jz .exit
    mov al, [op_stack + bp]
    call get_op_priority
    test bl, bl
    jz .exit
    cmp bl, bh
    jb .exit

    stosb
    dec word [op_stack_top]
    jmp .pull_ops_loop

.exit:
    pop ax
    mov [op_stack + bp], al
    inc word [op_stack_top]
    ret


; in:  al - op
; out: bl - priority
get_op_priority:
    cmp al, '+'
    jnz .not_plus
    mov bl, 1
    ret
.not_plus:
    cmp al, '-'
    jnz .not_minus
    mov bl, 1
    ret
.not_minus:
    cmp al, '*'
    jnz .not_star
    mov bl, 2
    ret
.not_star:
    cmp al, '/'
    jnz .not_slash
    mov bl, 2
    ret
.not_slash:
    xor bl, bl
    ret


welcome_msg db "Big calculator"
            db 'Press [F1] to see help menu', 0x0D, 0x0A
            db 'Press [ESC] to exit', 0x0D, 0x0A, 0
prompt      db '> ', 0

input_buffer   times 93 db 0
postfix_buffer times 93 db 0
op_stack       times 16 db 0
op_stack_top   dw 0

LPARENT_TOK equ 255

string_int_to_string:
    pusha
    mov cx, 0
    mov bx, 10
    mov di, .t

.push:
    mov dx, 0
    div bx
    inc cx
    push dx
    test ax, ax
    jnz .push
.pop:
    pop dx
    add dl, '0'
    mov [di], dl
    inc di
    dec cx
    jnz .pop
    mov byte [di], 0
    popa
    mov ax, .t
    ret

.t times 7 db 0