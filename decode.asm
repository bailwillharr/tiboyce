decode_jump_helper:
	ld bc,recompile_struct
	add ix,bc
	sub (ix+7)
	ld.s (hl),a
	
	ld bc,-$4000
	ld a,d
	add a,b
	add a,b
	jr nc,decode_jump_bank_switch
	
	call get_base_address
decode_jump_common:
	ld (base_address),hl
	add hl,de
	
	push hl
	 call lookup_code_link_internal_by_pointer
	pop hl
	
	push af
	 or a
	 call nz,identify_waitloop
	pop af
	
	ei
	jp.sis decode_jump_return
	
decode_jump_bank_switch:
	push de
	 ld hl,(ix+2)
	 ld de,(rom_bank_base)
	 sbc hl,de
	 add hl,bc
	 add hl,bc
	 ex de,hl
	pop de
	jr nc,decode_jump_common
	
	call lookup_code_link_internal_with_base
	pop.s hl
	add.s a,(hl)
	ld.s (hl),a	;cycle count
	dec hl
	ld a,(z80codebase+curr_rom_bank)
	ld.s (hl),a	;rom bank
	dec hl
	dec hl
	ld.s (hl),ix
	dec hl
	ld.s (hl),$C3	;JP target
	dec hl
	ld.s (hl),do_rom_bank_jump >> 8
	dec hl
	ld.s (hl),do_rom_bank_jump & $FF
	dec hl
	ld.s (hl),$CD	;CALL do_rom_bank_jump
	ei
	jp.sis decode_jump_waitloop_return
	
decode_rst_helper:
	push de
	 ex de,hl
	 call lookup_code_block
	 ex de,hl
	 ld a,(ix+7)
	 sub.s (hl)
	 ld.s (hl),a
	pop de
	call get_base_address
	add hl,de
	dec hl
	ld a,(hl)
	sub $C7
	ld e,a
	ld d,0
	jr decode_call_common
	
decode_call_helper:
	push de
	 ex de,hl
	 call lookup_code_block
	 ex de,hl
	 ld a,(ix+7)
	 sub.s (hl)
	 ld.s (hl),a
	pop de
	push hl
	 call get_base_address
	 ld a,d
	 add hl,de
	 dec hl
	 ld d,(hl)
	 dec hl
	 ld e,(hl)
	 xor d
	pop hl
	and $C0
	jr nz,decode_call_bank_switch
decode_call_common:
	call lookup_code_link_internal
_
	add a,3	; Taken call eats 3 cycles
	ld b,RST_CALL
	ei
	ret.l
	
decode_call_flush:
	pop hl
	call prepare_flush
	xor a
	jr -_
	
decode_call_bank_switch:
	ld a,d
	sub $40
	cp $40
	jr nc,decode_call_common
	
	dec hl
	ld a,(z80codebase+curr_rom_bank)
	ld.s (hl),a
	
	push de
	 ld hl,(z80codebase+memroutine_next)
	 ld de,-5
	 add hl,de	;Sets C flag
	
	 ; Bail if not enough room for trampoline
	 ex de,hl
	 ld hl,(recompile_struct_end)
	 ld hl,(hl)
	 sbc hl,de	;Carry is set
	 ex de,hl
	 ld (z80codebase+memroutine_next),hl
	 jr nc,decode_call_flush
	 ld de,ERROR_CATCHER
	 ld (hl),de
	 inc hl
	 inc hl
	 inc hl
	pop de
	; Code lookup may overwrite the trampoline area, so wait to write it out
	push hl
	 call lookup_code_link_internal
	 add a,3	; Taken call eats 3 cycles
	 ex (sp),ix
	pop hl
	ld.s (ix+3),hl	;JIT target
	ld hl,(do_rom_bank_call << 8) | $CD	; CALL do_rom_bank_call
	ld (ix),hl
	ld b,l	;CALL
	ei
	ret.l
	
decode_ret_cond_helper:
	ex de,hl
	call lookup_code_block
	ex de,hl
	ld.s a,(hl)
	sub (ix+7)
	ei
	ret.l
	
banked_jump_mismatch_helper:
	exx
	push bc
	 push hl
	  ; Look up the old target
	  ld.s de,(ix+1)
	  push ix
	   call.il lookup_gb_code_address
	   ex (sp),ix
	   ld.s hl,(ix+3)
	   add a,h
	   ld h,3
	   mlt hl
	   ld de,rombankLUT
	   add hl,de
	   ld de,(hl)
	  pop hl
	  sbc hl,de
	  ex de,hl
	  push ix
	   ld h,a
	   call.il lookup_code_cached
	   add a,h
	   ld.sis hl,(curr_rom_bank)
	   ld h,a
	   ex (sp),ix
	   ld.s (ix+3),hl
	  pop hl
	  ld.s (ix+1),hl
	  ex (sp),hl
	 pop ix
	pop bc
	ei
	jp.sis dispatch_cycles_exx
	
banked_call_mismatch_helper:
	ld.s (ix+2),a
	push bc
	 push hl
	  ld.s de,(ix)
	  call get_base_address
	  add hl,de
	  dec hl
	  ld d,(hl)
	  dec hl
	  ld e,(hl)
	  push ix
	   call.il lookup_code_cached
	   add a,3	; Taken call eats 3 cycles
	   pop.s hl
	   ld.s (hl),ix
	   push.s hl
	  pop ix
	  sub.s (ix+3)
	  ld.s (ix+4),a
	 pop hl
	pop bc
	ei
	jp.sis banked_call_mismatch_continue
	
decode_intcache_helper:
	ld e,c
	ld d,0
	call lookup_code
	; Spend 5 cycles for interrupt dispatch overhead
	add a,5
memroutine_gen_ret:
	ei
	ret.l
	
; Most emitted single-byte memory access instructions consist of RST_MEM
; followed inline by the opcode byte in question (and one padding byte).
;
; Each unique combination of an opcode byte and a memory region can receive
; its own memory access routine that incorporates both. This routine
; determines the routine associated with the instruction in question
; and returns it to be patched into a direct call.
;
; Opcode identifiers:
;   0-1 = ld (bc),a \ ld a,(bc)
;   2-3 = ld (de),a \ ld a,(de)
;   4-5 = ldi (hl),a \ ldi a,(hl)
;   6-7 = ldd (hl),a \ ldd a,(hl)
;   8-13,15 = ld r,(hl)
;   16-23 = op a,(hl)
;   24-29,31 = ld (hl),r
;   14,30 = unused
;
; Memory region identifiers:
;   0 = HRAM ($FF80 - $FFFE)
;   1 = Static ROM ($0000-$3FFF)
;   2 = OAM/MMIO/HRAM ($FE00-$FFFF), region 0 takes precedence
;   3 = Banked ROM ($4000-$7FFF)
;   4 = VRAM ($8000-$9FFF)
;   5 = Cart RAM ($A000-$BFFF)
;   6 = WRAM ($C000-$DFFF)
;   7 = WRAM Mirror ($E000-$FDFF)
;
; The memory access routines grow backwards in the JIT code region, and if
; the JIT code and the memory access routines overlap a flush must occur.
; If this case is detected, a pointer to a flush handler is returned instead.
;
; When a memory access routine is called with an address outside its assigned
; memory region, decode_mem is called with the new region and the direct call
; is patched again with the new memory access routine.
;
; Inputs:  IX = address following the RST_MEM instruction
;          BCDEHL = Game Boy BCDEHL
; Outputs: IX = address of the RST_MEM instruction
;          DE = address of the memory access routine
; Destroys AF,HL
decode_mem_helper:
	dec ix
	
	; Get index 0-31
	ld.s a,(ix+1)
	sub $70
	cp 8
	jr c,++_
_
	add a,$70+$40
	rrca
	rrca
	rrca
	or $E0
_
	add a,24
	
	; Check for BC access
	cp 2
	jr nc,_
	ld d,b
	ld e,c
_
	; Check for HL access 
	cp 4
	jr c,_
	ex de,hl
_
	
	; Address is now in DE
	ld hl,memroutineLUT
	ld l,a
	
	; Get memory region, 0-7
	ld a,d
	cp $FE
	jr c,++_
	inc e	; Exclude $FFFF from region 0
	jr z,_
	dec e
_
	rrca
	and e
	rrca
	cpl
	and $40
	jr ++_
_
	and $E0
	jp m,_
	set 5,a
_
	or l
	ld l,a
	
	; Get routine address
	ld e,(hl)
	inc h
	ld d,(hl)
	ld a,d
	or e
	jr nz,memroutine_gen_ret
	
	; Routine doesn't exist, let's generate it!
	push bc \ push hl
	 ex de,hl
	 ld.s d,(ix+1)
	 
	 ; Emit RET and possible post-increment/decrement
	 ld hl,(z80codebase+memroutine_next)
	 inc hl
	 inc hl
	 ld (hl),$C9	;RET
	 ld a,e
	 and $1C
	 cp 4
	 jr nz,++_
	 ld a,e
	 rra
	 ld d,$77	;LD (HL),A
	 jr nc,_
	 ld d,$7E	;LD A,(HL)
_
	 dec hl
	 rra
	 ld (hl),$23 ;INC HL
	 jr nc,_
	 ld (hl),$2B ;DEC HL
_
	 dec hl
	  
	 ; Get register pair index (BC=-4, DE=-2, HL=0)
	 ld a,e
	 and $1E
	 sub 4
	 jr c,_
	 xor a
_
	 ld c,a
	 
	 ld a,e
	 rlca
	 rlca
	 rlca
	 and 7
	 jr nz,memroutine_gen_not_high
	 
	 ld (hl),d
	 dec hl
	 ld (hl),$08 ;EX AF,AF'
	 dec hl
	 ld (hl),-10
	 dec hl
	 ld (hl),$20 ;JR NZ,$-8
	 dec hl
	 ld (hl),$3C ;INC A
	 dec hl
	 ld a,c
	 add a,$A4 ;AND B/D/H
	 ld (hl),a
	 dec hl
	 ld (hl),$9F ;SBC A,A
	 dec hl
	 ld (hl),$17 ;RLA
	 dec hl
	 add a,$7D-$A4 ;LD A,C/E/L
	 ld (hl),a
	 
memroutine_gen_end_swap:
	 dec hl
	 ld (hl),$08 ;EX AF,AF' 
memroutine_gen_end:
	 push hl
	  dec hl
	  ld.s a,(ix+1)
	  ld (hl),a
	  dec hl
	  ld (hl),RST_MEM
	  dec hl
	  dec hl
	  dec hl
	  ld de,ERROR_CATCHER
	  ld (hl),de
	  ld (z80codebase+memroutine_next),hl
	  ex de,hl
	  ld hl,(recompile_struct_end)
	  ld hl,(hl)
	  scf
	  sbc hl,de
	 pop de
	 jr nc,memroutine_gen_flush
_
	pop hl \ pop bc
	
	ld (hl),d
	dec h
	ld (hl),e
	ei
	ret.l
	
memroutine_gen_flush:
	ld hl,recompile_cache_end
	ld (recompile_cache),hl
	ld de,flush_mem_handler
	jr -_
	
memroutine_gen_not_high:
	 ld b,a
	 
	 ; Get HL-based access instruction for BC/DE accesses
	 ld a,e
	 and $1C
	 jr nz,_
	 bit 0,e
	 ld d,$77	;LD (HL),A
	 jr z,_
	 ld d,$7E	;LD A,(HL)
_
	 ; Set carry if write instruction
	 ld a,d
	 sub $70
	 sub 8
	 
	 djnz memroutine_gen_not_cart0
	 jr c,memroutine_gen_write_cart
	 
	 call memroutine_gen_index
	 ld de,(rom_start)
	 ld (hl),de
	 dec hl
	 ld (hl),$21
	 dec hl
	 ld (hl),$DD
	 dec hl
	 ld (hl),$5B	;LD.LIL IX,ACTUAL_ROM_START
	 dec hl
	 ld (hl),-8
	 dec hl
	 ld (hl),$30	;JR NC,$-6
	 dec hl
	 ld (hl),$40
	 dec hl
	 ld (hl),$FE	;CP $40
	 dec hl
	 ld a,c
	 add a,$7C	;LD A,B/D/H
	 ld (hl),a
	 jr memroutine_gen_end_swap
	 
memroutine_gen_write_ports:
	 ld de,mem_write_ports
memroutine_gen_write:
	 inc a
	 jr z,_
	 ld (hl),$F1	;POP AF
	 dec hl
_
	 ld (hl),d
	 dec hl
	 ld (hl),e
	 dec hl
	 ld (hl),$CD	;CALL routine
	 jr z,_
	 dec hl
	 add a,$7F	;LD A,r
	 ld (hl),a
	 dec hl
	 ld (hl),$F5	;PUSH AF
_
	 call memroutine_gen_load_ix
	 jp memroutine_gen_end
	 
memroutine_gen_not_cart0:
	 djnz memroutine_gen_not_ports
	 jr c,memroutine_gen_write_ports
	 
	 dec d
	 ld (hl),d	;Access IXL instead of (HL)
	 ;Special case for loading into H or L
	 ld a,d
	 and $F0
	 cp $60
	 jr nz,_
	 ld (hl),$EB	;EX DE,HL
	 dec hl
	 res 5,d
	 set 4,d
	 ld (hl),d
_
	 dec hl
	 ld (hl),$DD
	 jr nz,_
	 dec hl
	 ld (hl),$EB	;EX DE,HL
_
	 dec hl
	 ld (hl),mem_read_ports >> 8
	 dec hl
	 ld (hl),mem_read_ports & $FF
	 dec hl
	 ld (hl),$CD	;CALL mem_read_ports
	 call memroutine_gen_load_ix	;LD IX,BC/DE/HL
	 jp memroutine_gen_end
	 
memroutine_gen_write_cart:
	 ld de,mem_write_cart
	 jr memroutine_gen_write
	 
memroutine_gen_write_vram:
	 ld de,mem_write_vram
	 jr memroutine_gen_write
	 
memroutine_gen_not_cart_bank:
	 djnz memroutine_gen_not_vram
	 jr c,memroutine_gen_write_vram
	 
	 call memroutine_gen_index
	 ld de,vram_base
	 ld (hl),de
	 dec hl
	 ld (hl),$21
	 dec hl
	 ld (hl),$DD
	 dec hl
	 ld (hl),$5B	;LD.LIL IX,vram_base
	 ex de,hl
	 ld hl,-9
	 add hl,de
	 ex de,hl
	 dec hl
	 ld (hl),d
	 dec hl
	 ld (hl),e
	 dec hl
	 ld (hl),$E2	;JP PO,$-6
	 dec hl
	 ld (hl),$20
	 dec hl
	 ld (hl),$D6	;SUB $20
	 dec hl
	 ld a,c
	 add a,$7C	;LD A,B/D/H
	 ld (hl),a
	 jp memroutine_gen_end_swap
	 
memroutine_gen_not_ports:
	 djnz memroutine_gen_not_cart_bank
	 jr c,memroutine_gen_write_cart
	 
	 call memroutine_gen_index
	 ld de,rom_bank_base
	 ld (hl),de
	 dec hl
	 ld (hl),$2A
	 dec hl
	 ld (hl),$DD
	 dec hl
	 ld (hl),$5B	;LD.LIL IX,(rom_bank_base)
	 ex de,hl
	 ld hl,-9
	 add hl,de
	 ex de,hl
	 dec hl
	 ld (hl),d
	 dec hl
	 ld (hl),e
	 dec hl
	 ld (hl),$E2	;JP PO,$-6
	 dec hl
	 ld (hl),$40
	 dec hl
	 ld (hl),$C6	;ADD A,$40
	 dec hl
	 ld a,c
	 add a,$7C	;LD A,B/D/H
	 ld (hl),a
	 jp memroutine_gen_end_swap
	 
memroutine_gen_not_vram:
	 djnz memroutine_gen_not_cram
	
	 sbc a,a
memroutine_rtc_smc_1 = $+1
	 and 0	; 5 when RTC bank selected
	 call memroutine_gen_index_offset
	 ld de,cram_bank_base
	 ld (hl),de
memroutine_rtc_smc_2 = $
	 jr _   ; JR C when RTC bank selected
	 ld de,5
	 cp 1
	 push hl
	  adc hl,de
	  ld a,(hl)
	  xor $09 ^ $84	;ADD.L IX,rr vs op.L A,IXH
	  ld (hl),a
	 pop hl
_
	 dec hl
	 ld (hl),$2A
	 dec hl
	 ld (hl),$DD
	 dec hl
	 ld (hl),$5B	;LD.LIL IX,(cram_bank_base)
	 dec hl
	 ld (hl),-10
	 dec hl
	 ld (hl),$30	;JR NC,$-8
	 dec hl
	 ld (hl),$20
	 dec hl
	 ld (hl),$FE	;CP $20
	 dec hl
	 ld (hl),$A0
	 dec hl
	 ld (hl),$D6	;SUB $A0
	 dec hl
	 ld a,c
	 add a,$7C	;LD A,B/D/H
	 ld (hl),a
	 jp memroutine_gen_end_swap
	
memroutine_gen_not_cram:
	 ;We're in RAM, cool!
	 call memroutine_gen_index
	 ;Mirrored RAM
	 ld de,wram_base-$2000
	 ld a,$1E
	 djnz _
	 ;Unmirrored RAM
	 ld de,wram_base
	 ld a,$20
_
	 ld (hl),de
	 dec hl
	 ld (hl),$21
	 dec hl
	 ld (hl),$DD
	 dec hl
	 ld (hl),$5B	;LD.LIL IX,wram_base
	 dec hl
	 ld (hl),-10
	 dec hl
	 ld (hl),$30	;JR NC,$-8
	 dec hl
	 ld (hl),a
	 dec hl
	 ld (hl),$FE	;CP $1E / $20
	 dec hl
	 cpl
	 and $E0
	 ld (hl),a
	 dec hl
	 ld (hl),$D6	;SUB $E0 / $C0
	 dec hl
	 ld a,c
	 add a,$7C	;LD A,B/D/H
	 ld (hl),a
	 jp memroutine_gen_end_swap
	
memroutine_gen_index:
	 xor a
memroutine_gen_index_offset:
	 ld (hl),a	;offset
	 dec hl
	 ld (hl),d	;opcode
	 dec hl
	 ld (hl),$DD	;IX prefix
	 dec hl
	 ld (hl),$5B	;.LIL prefix
	 dec hl
	 ld (hl),$08	;EX AF,AF'
	 dec hl
	 ld a,c
	 or a
	 jr nz,_
	 ld (hl),$EB	;EX DE,HL	(if accessing HL)
	 dec hl
	 ld a,-2
_
	 add a,a
	 add a,a
	 add a,a
	 add a,$29
	 ld (hl),a
	 dec hl
	 ld (hl),$DD
	 dec hl
	 ld (hl),$5B	;ADD.LIL IX,BC/DE/DE
	 dec hl
	 ld a,c
	 or a
	 jr nz,_
	 ld (hl),$EB
	 dec hl
_
	 dec hl
	 dec hl
	 ret
	
memroutine_gen_load_ix:
	 dec hl
	 ld (hl),$E1
	 dec hl
	 ld (hl),$DD	;POP IX
	 dec hl
	 ld a,c
	 add a,a
	 add a,a
	 add a,a
	 add a,$E5	;PUSH BC/DE/HL
	 ld (hl),a
	 ret