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