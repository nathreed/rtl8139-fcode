\ Main RTL8139 driver
fcode-version3
	hex
	external \ ensure all functions defined here are visible externally after execution has completed

	." begin nathan's RTL8139 FCode!" cr

	\ workaround for Apple Open Firmware being broken
	\ see https://web.archive.org/web/20060315035741/playground.sun.com/pub/1275/proposals/Closed/Accepted/303-it.txt
	\ see PCI bindings to 1275 pp22-23

	: map-in-broken? ( -- flag ) \ flag is true if parent's map-in method is broken
		\  Look for the method that is present when the bug is present
		" add-range" my-parent ihandle>phandle ( adr len phandle )
		find-method dup if nip then ( flag ) \ Discard xt if present
	;

	\ Return phys.lo and phys.mid of the address assigned to the PCI base address register indicated by phys.hi
	: get-base-address ( phys.hi -- phys.lo phys.mid phys.hi )

		" assigned-addresses" get-my-property if ( phys.hi )
			." No address property found!" cr
			0 0 rot exit \ Error exit
		then ( phys.hi adr len )

		rot >r ( adr len ) ( r: phys.hi )
		\ Found assigned-addresses, get address
		begin dup while ( adr len' ) \ Loop over entries
			decode-phys ( adr len' phys.lo phys.mid phys.hi )
			h# ff and r@ h# ff and = if ( adr len' phys.lo phys.mid ) \ This one?
				2swap 2drop ( phys.lo phys.mid ) \ This is the one
				r> exit ( phys.lo phys.mid phys.hi )
			else ( adr len' phys.lo phys.mid ) \ Not this one
				2drop ( adr len' )
			then ( adr len' )
			decode-int drop decode-int drop \ Discard boring fields
		repeat
		2drop ( )
		
		." Base address not assigned!" cr

		0 0 r> ( 0 0 phys.hi )
	;

	0 instance value op-regs-base \ base virtual address for RTL8139 operational registers, mapped in during open function

	: open
		\ Enable memory space access and bus mastering
		my-space 04 + " config-w@" $call-parent \ ( -- config register 04) - read command register
		6 or \ (command reg contents -- modified command reg contents) - 0x06 = bit 1 and 2 set (memory space & bus master)
		my-space 04 + " config-w!" $call-parent \ (modified command reg contents -- ) - write modified command register back enabling memory-space access and bus mastering

		\ map in BAR1 (offset in config space 0x14) for operational registers
		map-in-broken? if
			my-space 14 + get-base-address 	( phys.lo, mid, hi )
		else
			0 0 my-space 14 +				( phys.lo, mid, hi )
		then

		\ do mapping (256 bytes)
		0100 " map-in" $call-parent to op-regs-base

		\ return true for successful open
		true

	;

	: close
		\ Unmap operational register base address
		op-regs-base 0100 " map-out" $call-parent
		\ Disable memory space access and bus mastering
		0 my-space 04 + " config-w!" $call-parent \ write 0 to command register (04)
	;

	: rtl-reg-read	( reg offset -- 1 byte of data from that offset )
		op-regs-base + \ compute offset into operational registers area
		rb@ \ do the read and return the value
	;

	." all methods defined!" cr
fcode-end