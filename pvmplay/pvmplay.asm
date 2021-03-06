; PVM (Play VGM Music) player
; Author: riq/pvm
;
; PIC & IRQ init code: taken from tandysnd.asm by @bisqwit
; PIC & IRQ fixes: by @trixter

bits    16
cpu     8086

; Timing settings:
PIT_divider     equ (262*76)                    ;262 lines * 76 PIT cycles each
                                                ; (14318180 / 12) / 19912 = 59.9227 Hz

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
; CODE
;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
section .text code
..start:

main:
        mov     ax,data                         ;init DS segment = data
        mov     ds,ax                           ;es should not be modified
        mov     ax,stack
        cli                                     ;disable interrupts while
        mov     ss,ax                           ; setting the stack pointer
        mov     sp,stacktop
        sti
        cld                                     ;direction forward

        mov     dx,msg_title
        call    print_msg

        call    verify_tandy

        call    parse_cmd_line                  ;es must remain intact until this
        call    load_song
        call    verify_song

        call    music_init                      ;must be called before setup_irq
        call    video_init
        call    setup_irq

        call    player_main

        call    restore_irq
        call    sound_cleanup

        mov     ax,0x0002
        int     0x10                            ;restore video mode, clean screen

        mov     ax,0x4c00                       ;Terminate program
        int     0x21                            ;INT 21, AH=4Ch, AL=exit code

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
print_msg:
        mov     ah,9
        int     0x21
        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
verify_tandy:
        ;FIXME: Detect Tandy/PC Jr.
        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
parse_cmd_line:
        ;FIXME: if song name has '/' in it, it will fail
        push    ds
        push    es

        push    ds                              ;swap ds,es
        push    es
        pop     ds
        pop     es

        mov     di,filename                     ;location for name
        mov     si,0x81                         ;params are in ds:si
        sub     bx,bx                           ;bx=0: invalid params

.loop:
        lodsb                                   ;al <- ds:si ( si++)
        cmp     al,0x20                         ;space?
        je      .loop                           ;keep reading if it is space
        cmp     al,13                           ;return?
        je      .exit                           ;if so, exit
        cmp     al,'/'                          ;argument?
        je      .parse_option

        mov     bl,1                            ;bx != 0 means arg was passed

        stosb                                   ;write name in es:di
        jmp     .loop                           ; and keep reading

.parse_option:
        lodsb
        cmp     al,13
        je      .exit
        and     al,0dfh                         ;to uppercase
        cmp     al,'R'                          ;enable raster?
        jne     .error
        mov     byte [es:enable_raster],1       ;turn on raster
        jmp     .loop

.exit:
        mov     al,0
        stosb                                   ;es:di -> 0 (asciiz)
        mov     al,'$'                          ;to show filename
        stosb

        cmp     bx,0                            ;arg was passed?
        je      .error
        pop     es
        pop     ds
        ret

.error:
        pop     es
        pop     ds
        mov     dx,msg_help
        jmp     exit_with_error

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
verify_song:
        push    ds

        mov     ax,pvmsong
        mov     ds,ax

        cmp     word [0],'PV'                   ;PV
        jne     .error
        cmp     word [2],'M '                   ;'M '
        jne     .error

        pop     ds
        ret

.error:
        pop     ds

        mov     dx,msg_error_fmt
        jmp     exit_with_error

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
load_song:
        push    ds

        mov     dx,msg_loading
        call    print_msg
        mov     dx,filename
        call    print_msg
        mov     dx,msg_enter
        call    print_msg

        mov     ah,3dh                          ;open file
        mov     al,0
        mov     dx,filename
        int     21h
        jc      .error

        mov     bx,ax                           ;file handle
        mov     cx,0xffff                       ;bytes to read: entire segment
        xor     dx,dx
        mov     ax,pvmsong
        mov     ds,ax                           ;dst: pvmsong segment:0
        mov     ah,0x3f                         ;read file
        int     0x21
        jc      .error

        mov     ah,0x3e                         ;close fd
        int     0x21
        jc      .error                          ;error? exit

        pop     ds
        ret

.error:
        pop     ds

        mov     dx,msg_error_load               ;print error message and exit
        jmp     exit_with_error

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
; in:
;       dx = pointer to error message. '$' terminated

exit_with_error:
        call    print_msg
        mov     ax,0x4c02
        int     0x21

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
wait_vert_retrace:
        mov     dx,0x03da

.wait_retrace_finish:                           ;if retrace already started, wait
        in      al,dx                           ; until it finishes
        test    al,8
        jnz     .wait_retrace_finish

.wait_retrace_start:
        in      al,dx                           ;wait until start of the retrace
        test    al,8
        jz      .wait_retrace_start

        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
wait_horiz_retrace:
        mov     dx,0x03da
.wait_retrace_finish:                            ;wait for horizontal retrace start
        in      al,dx
        test    al,1
        jnz      .wait_retrace_finish

.wait_retrace_start:
        in      al,dx                           ;wait until start of the retrace
        test    al,1
        jz      .wait_retrace_start
        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
setup_irq:
        call    wait_vert_retrace               ;so raster shows more or less always

        mov     cx,80                           ;and wait for 20 after the vert retrace
.repeat:
        call    wait_horiz_retrace
        loop    .repeat

        cli

        push    ds
        xor     ax,ax
        mov     ds,ax

        mov     ax,new_i08
        mov     dx,cs
        xchg    ax,[ds:8*4]
        xchg    dx,[ds:8*4+2]
        mov     [cs:old_i08],ax
        mov     [cs:old_i08+2],dx

        pop     ds

        mov     ax,PIT_divider                  ;Configure the PIT to
        call    setup_PIT                       ;issue IRQ at 60 Hz rate

        in      al,0x21                         ;Read primary PIC Interrupt Mask Register
        mov     [old_pic_imr],al                ;Store it for later
        mov     al,0b1111_1100                  ;Mask off everything except IRQ 0
        out     0x21,al                         ; and IRQ1 (timer and keyboard)

        sti
        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
restore_irq:
        cli

        mov     al,[old_pic_imr]                ;Get old PIC settings
        out     0x21,al                         ;Set primary PIC Interrupt Mask Register

        mov     ax,0                            ;Reset PIT to defaults (~18.2 Hz)
        call    setup_PIT                       ; actually means 10000h

        push    ds
        xor     ax,ax
        mov     ds,ax
        les     si,[cs:old_i08]
        mov     [ds:8*4],si
        mov     [ds:8*4+2],es                   ;Restore the old INT 08 vector
        pop     ds

        sti
        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
music_init:
        in      al,0x61
        or      al,0b0110_0000                  ;PCJr. only: Use 76496
        out     0x61,al                         ; instead of internal speaker

        mov     word [pvm_offset],0x10          ;update start offset
        mov     byte [pvm_wait],0               ;don't wait at start
        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
video_init:
        cmp     byte [enable_raster],0
        je      .exit

        mov     ax,0x0009                       ;320x200 x 16 colors
        int     0x10

        mov     dx,0x03de
        mov     al,0b0001_0100                  ;enable border color, enable 16 colors
        out     dx,al

        mov     dx,0x03da
        mov     al,2                            ;select border color
        out     dx,al

        add     dx,4
        mov     al,0
        out     dx,al                           ;change border to black

.exit:
        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
player_main:
        mov     dx,msg_playing
        call    print_msg

.mainloop:
        hlt                                     ;wait for IRQ

.l2:
        ; Loop until some input is given
        mov     ah,1
        int     0x16                            ;INT 16,AH=1, OUT:ZF=status
        jz      .mainloop

        ; Read the input key
        xor     ax,ax
        int     0x16                            ;INT 16,AH=0, OUT:AX=key
        ret


;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
wait_key:
        xor     ah,ah                           ;Function number: get key
        int     0x16                            ;Call BIOS keyboard interrupt
        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
setup_PIT:
        ; AX = PIT clock period
        ;          (Divider to 1193180 Hz)
        push    ax
        mov     al,0x34
        out     0x43,al
        pop     ax
        out     0x40,al
        mov     al,ah
        out     0x40,al

        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
sound_cleanup:
        mov     si,volume_0
        mov     cx,4
.repeat:
        lodsb
        out     0xc0,al
        loop    .repeat

        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
inc_d020:
        mov     dx,0x03da                       ;show how many raster barts it consumes
        mov     al,2                            ;select border color
        out     dx,al

        add     dx,4
        mov     al,0x0f
        out     dx,al                           ;change border to white

        sub     dx,4                            ;update palette
        mov     al,0x10                         ;select color=0
        out     dx,al                           ;select palette register

        add     dx,4
        mov     al,0x0f                         ;color black in white now
        out     dx,al

        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
dec_d020:
        mov     dx,0x03da                       ;show how many raster barts it consumes
        mov     al,2                            ;select border color
        out     dx,al

        add     dx,4
        sub     al,al
        out     dx,al                           ;change border back to black

        sub     dx,4                            ;update palette
        mov     al,0x10                         ;select color=0
        out     dx,al                           ;select palette register

        add     dx,4
        sub     al,al                           ;color black is back to black
        out     dx,al

        ret

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
song_tick:

DATA    equ     0b0000_0000
DATA_EXTRA equ  0b0010_0000
DELAY   equ     0b0100_0000
DELAY_EXTRA equ 0b0110_0000
END     equ     0b1000_0000

        push    ax
        push    cx
        push    dx
        push    si
        push    ds
        push    es

        mov     ax,data                         ;vars in es
        mov     es,ax
        mov     ax,pvmsong                      ;song in ds
        mov     ds,ax

        cmp     byte [es:enable_raster],0
        je      .l0
        call    inc_d020

.l0:
        sub     cx,cx                           ;cx=0... needed later
        mov     si,[es:pvm_offset]

        cmp     byte [es:pvm_wait],0
        je      .l1

        dec     byte [es:pvm_wait]
        jmp     .exit

.l1:
        lodsb                                   ;fetch command byte
        mov     ah,al
        and     al,0b1110_0000                  ;al=command only
        and     ah,0b0001_1111                  ;ah=command args only

        cmp     al,DATA                         ;data?
        je      .is_data
        cmp     al,DATA_EXTRA                   ;data extra?
        je      .is_data_extra
        cmp     al,DELAY                        ;delay?
        je      .is_delay
        cmp     al,DELAY_EXTRA                  ;delay extra?
        je      .is_delay_extra
        cmp     al,END                          ;end?
        je      .is_end

.unsupported:
        int 3
        jmp     .exit


;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
.is_data:
        mov     cl,ah                           ;ch is already zero
        jmp     .repeat

.is_data_extra:
        lodsb                                   ;fetch lenght from next byte
        mov     cl,al                           ;new repeat value taken from prev. fetch
.repeat:
        lodsb
        out     0xc0,al
        loop    .repeat

        jmp     .l1                             ; start again. fetch next command


;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
.is_delay:
        dec     ah                              ;minus one, since we are returning
        mov     [es:pvm_wait],ah                ; from here now
        jmp     .exit

.is_delay_extra:
        lodsb                                   ;fetch wait from next byte
        dec     al                              ;minus one, since we are returning
        mov     [es:pvm_wait],al                ; from here now
        jmp     .exit

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
.is_end:
        test    byte [0x0b],1
        jz      .exit_song

        mov     ax,[0xc]                        ;offset loop relative to start of data
        add     ax,0x10                         ;add header size
        mov     word [es:pvm_offset],ax         ;update new offset with loop data
        jmp     .exit_skip

.exit_song:
        mov     byte [es:exit_song],1
        jmp     .exit_skip

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
.exit:
        mov     [es:pvm_offset],si
.exit_skip:

        cmp     byte [es:enable_raster],0
        je      .l2
        call    dec_d020
.l2:
        pop     es
        pop     ds
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret


;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
; IRQ
;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
new_i08:
        call    song_tick

        add     word [cs:i08_counter],PIT_divider
        jnc     skip_old_i08
        db      0xea                            ;Jump far...
old_i08:        dd 0                            ; ...to Old INT 08 vector

skip_old_i08:
        push    ax
        mov     al,0x20                         ;Send the EOI signal
        out     0x20,al                         ; to the IRQ controller
        pop     ax

        iret                                    ;Exit interrupt

; I08counter makes it possible to call the
; the old IRQ vector at the right rate.
; At every INT, it is incremented by:
;       10000h * (oldrate/newrate)
; Which happens to evaluate into the same
; as PITdivider when the oldrate is the
; standard ~18.2 Hz. Whenever it overflows,
; it's time to call the old IRQ handler.
; This ensures that the old IRQ handler is
; called at the standard 18.2 Hz rate.
i08_counter:
        dw      0

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
; section DATA
;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
section .data data

;messages
msg_title:      db 'pvmplay v0.1 - riq/pvm - http://pungas.space',13,10,13,10,'$'
msg_help:       db 'usage:',13,10
                db '   pvmplay [/r] songname.pvm',13,10,13,10,'$'
msg_loading:    db 'loading ','$'
msg_playing:    db 'playing...',13,10,'$'
msg_error_load: db 'error loading',13,10,'$'
msg_error_fmt:  db 'invalid format',13,10,'$'
msg_enter:      db 13,10,'$'

;vars
filename:
        resb    64                              ;64 bytes for the name

pvm_wait:                                       ;cycles wait
        db      0

pvm_offset:                                     ;pointer to next byte to read
        dw      0

old_pic_imr:
        db      0                               ;PIC IMR original value

volume_0:
        db      0b1001_1111                     ;vol 0 channel 0
        db      0b1011_1111                     ;vol 0 channel 1
        db      0b1101_1111                     ;vol 0 channel 2
        db      0b1111_1111                     ;vol 0 channel 3

enable_raster:
        db      0                               ;boolean. if 1, display raster bars

exit_song:
        db      0                               ;if 1, song is over

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
; section STACK
;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
section .pvmsong data
        resb    65536

;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
; section STACK
;=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-;
section .stack stack
        resb    1024
stacktop:
