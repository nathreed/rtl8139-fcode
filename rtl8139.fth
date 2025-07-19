\ Main RTL8139 driver
fcode-version3
	hex
	external \ ensure all functions defined here are visible externally after execution has completed

	\ See file for details, Apple Open Firmware broken for map-in
	fload apple_workaround.fth

	\ Constants for RTL8139 driver
	100 constant op-regs-len
	37 constant command-register
	10 constant reset-delay-ms \ 16ms for SW reset
	d# 1600 constant tx-descriptor-len
	d# 34320 constant rx-buffer-len
	30 constant rx-buffer-reg
	44 constant recv-config-reg
	38 constant capr-reg \ Current Address of Packet Read (where we will start reading in the RX buffer next time we RX. 2-byte register)
	d# 1500 constant mtu \ Ethernet packet payload max MTU is 1500 bytes per standard
	64 constant tx-delay-ms \ 100ms for TX delay
	3a constant cbr-reg \ Current Buffer Address (where the device is writing in the RX buffer. 2-byte register)
	rx-buffer-len d# 1536 - constant rx-buffer-nominal-len \ Nominal length of RX buffer (ignoring 1.5K allocated for wrap overrun). Used to determine overrun amount for handling wrap behavior.
	3e constant isr-reg \ 2 byte register interrupt status
	3c constant imr-reg \ 2 byte register interrupt mask
	40 constant tx-config-reg \ 4 byte register, transmit configuration register (datasheet pp.14-15)
	60 constant tsad-reg \ transmit status of all descriptors, 2-byte register (datasheet pp.24)

	\ Instance values for RTL8139 driver
	0 instance value op-regs-base \ base virtual address for RTL8139 operational registers, mapped in during open function
	0 instance value rx-buffer-vaddr \ virtual address for RX buffer (34320 bytes)
	0 instance value rx-buffer-baddr \ bus address for RX buffer (34320 bytes)
	6 instance buffer: mac-buffer \ buffer to store MAC address
	0 instance value last-rx-wrap-len \ the number of bytes past the nominal length of the RX buffer the last received packet overran. Used to compute offset of next packet from top of RX buffer. See datasheet pp17 for WRAP behavior.
	0 instance value obp-tftp \ ihandle of TFTP boot package
	
	\ TX descriptors
	4 cells instance buffer: tx-descriptor-vaddrs
	4 cells instance buffer: tx-descriptor-baddrs
	\ Register offsets for descriptor status and start
	\ Used to compute the register offsets for all 4 descriptors
	10 constant tx-d0-status
	20 constant tx-d0-start

	\ keep track of which TX descriptor is up to be used next
	0 instance value next-tx-descriptor
	0 instance value next-tx-descriptor-vaddr
	0 instance value next-tx-descriptor-baddr
	tx-d0-status instance value next-tx-descriptor-status-reg

	\ Mac OS driver
	\ Needs to be read as soon as this FCode is run (i.e. on byte-load), the memory seems to already be clobbered when we get here in open method
	\ ac0e buffer: macos-driver-buffer
	\ 2001000 macos-driver-buffer ac0e move
	\ cr ." Copied Mac OS driver to own buffer. Beginning of that location: " macos-driver-buffer rl@ .h cr

	\ TEMP/DEBUG: Set debug property for Mac OS - hardcodes PCI layout from my power mac g4
	" dev /" evaluate
	\ 2137 encode-int " AAPL,debug" property \ some extra prints, mostly while copying device tree. Prints warning that EtherPrintf will stop OpenTransport from loading its Ethernet driver even though we're not loading EtherPrintf with this 
	\ 40000001 encode-int " AAPL,debug" property \ halt after end of FCode (this is right before boot would normally terminate OF and hand control to MacOS - useful for browsing device tree after Trampoline has finished)
	2020001 encode-int " AAPL,debug" property \ display nanokernel log during boot

	\ Debug: Hack a method into obp-tftp that we will use for reading the current block number
	\ This is used to activate logging past a certain block number
	" dev /packages/obp-tftp : nr-get-block# tftp-block# ;" evaluate

	\ Take us back to the device where we belong
	" dev pci1/@d/@4" evaluate

	\ Read RTL8139 operational register (1 byte)
	: reg-read	( reg offset -- 1 byte of data from that offset )
		op-regs-base + \ compute offset into operational registers area
		rb@ \ do the read and return the value
	;

	\ Write RTL8139 operational register (1 byte)
	: reg-write ( 1 byte of data to write, reg offset -- )
		op-regs-base + \ compute offset into operational registers area
		rb!	\ do the write
	;

	\ Read RTL8139 operational register (2 bytes)
	: reg-read2 ( reg offset -- 2 bytes of data from that offset )
		op-regs-base +
		rw@
	;

	\ Write RTL8139 operational register (2 bytes)
	: reg-write2 ( 2 bytes of data to write, reg offset -- )
		op-regs-base +
		rw!
	;

	\ Read RTL8139 operational register (4 bytes)
	: reg-read4 ( reg offset -- 4 bytes of data from that offset )
		op-regs-base + \ offset into operational registers
		rl@
	;

	\ Write RTL8139 operational register (4 bytes)
	: reg-write4 ( 4 bytes of data to write, reg offset -- )
		op-regs-base +
		rl!
	;

	\ Sync DMA region, use after writing/before reading
	: my-dma-sync ( virt devaddr size -- )
		" dma-sync" $call-parent
	; 

	\ Perform a software reset of the RTL8139
	\ see datasheet pp12
	: sw-reset ( -- )
		command-register reg-read \ read current value from command register 0x37
		10 or \ set bit 4 (reset)
		command-register reg-write \ write modified value to command register 0x37

		\ Wait for RTL8139 to clear reset bit 4 indicating it has completed reset
		\ Will wait max of 10ms for reset to occur
		reset-delay-ms 0 do
			1 ms \ delay
			command-register reg-read 10 and \ Read command register and mask out all bit the reset bit 4 ( -- byte)
			0 = if leave then \ exit loop if reset bit is cleared ( -- )
		loop

		\ Verify reset has completed
		command-register reg-read 10 and \ Read register and check bit 4 ( -- register value)
		0 = if
			." RTL8139: SW reset completed" cr
		else
			." RTL8139: SW reset not completed in allowed time!" cr
		then
	;

	\ Basic setup for TX operation (DMA allocation, transmit configuration)
	: setup-tx ( -- )
		\ Allocate DMA memory for TX descriptors, map the DMA, and program into device registers
		4 0 do
			tx-descriptor-len " dma-alloc" $call-parent dup dup \ allocate memory for this descriptor ( vaddr, vaddr, vaddr )
			tx-descriptor-len erase \ zero allocated memory ( vaddr, vaddr )
			i cells tx-descriptor-vaddrs + l! \ compute offset into TX descriptor vaddrs buffer and store (assumes 32-bit address) ( vaddr )
			tx-descriptor-len false " dma-map-in" $call-parent dup ( baddr, baddr )
			i cells tx-descriptor-baddrs + l! \ compute offset into TX descriptor baddrs buffer and store (assumes 32-bit address) ( baddr )
			tx-d0-start i 4 * + reg-write4 \ program bus address into the correct register (compute by multiplying i*4)
		loop

		\ Set DMA burst size in Transmit Configuration Register
		\ Also make sure 1,1 are set for interframe gap time since any other value violates the spec
		3000600 tx-config-reg reg-write4

		\ Enable transmit state machine (datasheet pp12 command register)
		command-register reg-read 4 or command-register reg-write

		\ Initial state for next TX descriptor
		tx-descriptor-vaddrs l@ to next-tx-descriptor-vaddr
		tx-descriptor-baddrs l@ to next-tx-descriptor-baddr
	;

	\ Basic setup for RX operation (DMA allocation, receive configuration)
	: setup-rx ( -- )
		\ Allocate DMA memory for Rx buffer
		\ Rx buffer will be 32K but we want to use wrapping. Total size will be 32K + 16 byte + 1536 bytes = 0x8610 bytes (34320 bytes)
		rx-buffer-len " dma-alloc" $call-parent to rx-buffer-vaddr

		\ Zero allocated memory to prevent issues
		rx-buffer-vaddr rx-buffer-len erase

		\ Program Rx buffer start address register
		\ Obtain bus address first
		rx-buffer-vaddr rx-buffer-len false " dma-map-in" $call-parent to rx-buffer-baddr
		\ Tell device about it (register 0x30-0x33 4 byte address)
		rx-buffer-baddr rx-buffer-reg reg-write4

		\ Enable receive state machine (datasheet pp12 command register)
		command-register reg-read 8 or command-register reg-write

		\ Set early Rx thresholds, Rx buffer length, and wrap mode in Receive Configuration Register (datasheet pp16)
		\ RCR contents will be 0xF69A
		\ no early RX threshold,
		\ no multiple early interrupt,
		\ only accept 64-byte error packets,
		\ Rx FIFO threshold none (DMA when whole packet received),
		\ 32K Rx buffer,
		\ max DMA burst 1024 bytes,
		\ wrap mode enabled,
		\ do not accept error,
		\ accept runt packets,
		\ accept broadcast packets,
		\ do not accept multicast packets,
		\ accept physical match,
		\ do not accept all packets)
		F69A recv-config-reg reg-write4 \ RCR is 0x44-0x47 4 byte register
	;

	\ Read the MAC address from the device and expose the mac-address property required by Open Firmware for network devices
	: setup-mac-addr ( -- )
		0 reg-read4 \ read first 4 bytes of MAC address
		mac-buffer rl! \ store these 4 bytes to the first 4 bytes of the buffer
		4 reg-read2 \ read last 2 bytes of MAC address
		mac-buffer 4 + rw! \ store these 2 bytes to the last 2 bytes of the buffer
		mac-buffer 6 encode-bytes " mac-address" property \ expose mac-address property with encoded bytes
		mac-buffer 6 encode-bytes " local-mac-address" property \ expose local-mac-address property as well (optional)
	;

	\ TFTP init copied from Sun driver example
	: init-obp-tftp ( -- okay? )
		" obp-tftp" find-package if my-args rot open-package else 0
		then
		dup to obp-tftp dup 0= if
		( phandle )
		( ihandle )
		( ihandle | 0 )
		." Cannot open OBP standard TFTP package" cr
		then
	;

	\ Open Firmware standard close function, clean up from device
	: close
		\ Unmap operational register base address
		op-regs-base op-regs-len " map-out" $call-parent
		\ Disable memory space access and bus mastering
		0 my-space 04 + " config-w!" $call-parent \ write 0 to command register (04)
		\ Unmap and free DMA memory for TX descriptors
		4 0 do
			tx-descriptor-baddrs i cells + l@ tx-descriptor-len " dma-map-out" $call-parent \ Unmap DMA for this bus address
			tx-descriptor-vaddrs i cells + l@ tx-descriptor-len " dma-free" $call-parent \ Free the allocated buffer
		loop
		\ Unmap and free Rx buffer
		rx-buffer-baddr rx-buffer-len " dma-map-out" $call-parent
		rx-buffer-vaddr rx-buffer-len " dma-free" $call-parent 

		obp-tftp ?dup if close-package then
	;


	\ Open Firmware standard open function, get the device ready for use
	: open
		\ Start with fresh line for any output we produce
		cr
		." Allocated memory at the beginning of open: " " dev /memory .properties dev pci1/@d/@4" evaluate cr
		\ Enable memory space access and bus mastering
		my-space 04 + " config-w@" $call-parent \ ( -- config register 04) - read command register
		6 or \ (command reg contents -- modified command reg contents) - 0x06 = bit 1 and 2 set (memory space & bus master)
		my-space 04 + " config-w!" $call-parent \ (modified command reg contents -- ) - write modified command register back enabling memory-space access and bus mastering

		\ map in BAR1 (offset in config space 0x14) for operational registers (256 bytes)
		map-in-broken? if
			my-space 14 + get-base-address 	( phys.lo, mid, hi )
		else
			0 0 my-space 14 +				( phys.lo, mid, hi )
		then
		
		\ Do the mapping
		op-regs-len " map-in" $call-parent to op-regs-base
		
		\ Perform SW reset to get RTL8139 ready for use
		sw-reset
		
		\ We do not need to enable autonegotiation by default...it is enabled by default (loaded from EEPROM)

		\ Setup for TX/RX operations - DMA allocation, configuration register programming, etc
		setup-tx
		setup-rx

		\ Expose mac-address property with correct value
		setup-mac-addr
		\ MTU property, 1580 is a somewhat arbitrary value set below 1600 bytes Tx descriptor allocation size
		mtu encode-int " max-frame-size" property

		" pci10ec,8139" device-name
		" network" device-type
		" ethernet" encode-string " network-type" property
		" network" encode-string " removable" property
		" net" encode-string " category" property
		" RTL8139 PCI" encode-string " model" property
		" pci10ec,8139" encode-string " compatible" property
		\ macos-driver-buffer ac0e encode-bytes " driver,AAPL,MacOS,PowerPC" encode-string property
		\ HACK: fcode-rom-offset, is this required for boot?
		0 encode-int " fcode-rom-offset" property

		\ obp-tftp init for booting
		init-obp-tftp 0= if close false exit then

		\ return true for successful open
		true
	;

	\ Increment the next Tx descriptor to be used
	: incr-tx-descriptor
		\ Increment index
		next-tx-descriptor 1 + 4 mod to next-tx-descriptor
		\ Increment vaddr
		tx-descriptor-vaddrs next-tx-descriptor cells + l@ to next-tx-descriptor-vaddr
		\ Increment baddr
		tx-descriptor-baddrs next-tx-descriptor cells + l@ to next-tx-descriptor-baddr
		\ Increment next status register
		next-tx-descriptor 4 * tx-d0-status + to next-tx-descriptor-status-reg
	;

	0 instance value should-dump
	\ Whether the packet size was adjusted to a minimum of 64 bytes (requiring a memory allocation and thus a memory free)
	0 instance value adjusted-pkt-addr

	\ Open Firmware standard write method for network device, returns actual number of bytes written
	\ Packet must be complete with all addressing information, including source hardware address
	: write ( src-addr len -- actual )
		dup mtu > if \ duplicate the length so we can use it again then make sure it's not greater than MTU
			." RTL8139: Attempted to write data exceeding one MTU, this is not implemented!" cr
			0 exit \ Return 0 bytes actually written
		then

		\ ." Begin TX with descriptor " next-tx-descriptor .h cr
		\ ." Status reg is " next-tx-descriptor-status-reg .h cr
		\ ." TSAD " tsad-reg reg-read2 .h cr
		\ ." TX src addr " over .h cr

		\ Log TFTP ack if dumping
		\ should-dump 0 > if
		\	over ( src-addr len src-addr ) 2c + w@ ." Sending TFTP ack " .d cr
		\ then

		\ Check if the provided packet is too small
		\ A size of 64 bytes works here, and 56 bytes did not (that was my first guess for 42 byte min payload + 14 byte ethernet header)
		dup d# 64 swap - dup 0 > if ( src-addr, len, amount below minimum 64 bytes )
			\ Provided packet length is less than 64 byte minimum, this will not be a valid packet if we send as is
			over + ( src-addr, original len, new len )
			alloc-mem ( src-addr, original len, new buffer address )
			dup to adjusted-pkt-addr \ store address for later freeing
			dup d# 64 erase \ Zero allocated memory
			dup >r swap \ Stash a copy of new buffer address on the return stack temporarily (src-addr, new addr, original len ) and ( new addr )
			move \ Do the copy
			r> d# 64 \ Stack is now (new-src-addr, new-len which is 64 )  
			\ should-dump 0 > if
			\	." Packet was smaller than minimum, adjusted" cr
			\ then
		else
			\ Provided packet length meets minimum, drop the negative delta and continue
			drop
		then

		\ 1. (src-addr, len, len) 2. (len, len, src-addr) 3. (len, len, src-addr, dest-addr) 4. (len, src-addr, dest-addr, len)
		dup rot next-tx-descriptor-vaddr rot \ make the arguments how we need for the move
		\ Copy the memory into the Tx descriptor
		move \ perform the memory copy, stack is now (len)

		\ Flush caches for DMA
		next-tx-descriptor-vaddr next-tx-descriptor-baddr tx-descriptor-len my-dma-sync

		\ Tell the device the size and give it the ownership of the TX buffer (one operation)
		dup ( len, len )
		\ use reg-write4 per datasheet "these registers are only permitted to write by double-word access"
		next-tx-descriptor-status-reg reg-write4 \ write data to TX descriptor status register. This is the size and then we also set OWN bit to 0, handing ownership of the buffer to the device
		\ stack is now (len), 

		\ Check bit 15 for TX completion
		\ Completion must happen within 10ms
		tx-delay-ms 0 do
			1 ms \ delay
			next-tx-descriptor-status-reg reg-read2 8000 and \ check bit 15
			0 > if leave then \ exit loop early if bit 15 is set (result is greater than 0)
		loop

		\ Verify we have completion
		next-tx-descriptor-status-reg reg-read2 8000 and
		0 > if
			\ should-dump 0 > if
			\	." Transmitted packet." cr
			\ then
			\ ." TX Status reg " next-tx-descriptor-status-reg reg-read2 .h cr
			\ ." ISR " isr-reg reg-read2 .h cr
			\ ." TSAD " tsad-reg reg-read2 .h cr
			\ ." End TX for descriptor " next-tx-descriptor .h ." , incrementing" cr
			incr-tx-descriptor
		else
			\ should-dump 0 > if
			\	." Packet did not transmit in time!" cr
			\ then
			\ Output tx descriptor status reg for debug purposes
			\ ." TX Status reg " next-tx-descriptor-status-reg reg-read2 .h cr
			\ ." TSAD " tsad-reg reg-read2 .h cr
			\ ." End TX for descriptor " next-tx-descriptor .h ." , incrementing" cr
			incr-tx-descriptor
			drop 0 exit \ drop full packet len, replace with 0, return
		then

		\ If we allocated memory for adjusting the packet size earlier, we must free it.
		adjusted-pkt-addr 0<> if
			adjusted-pkt-addr d# 64 free-mem
			0 to adjusted-pkt-addr
		then

		\ len is still on the stack; we return it because we have written the whole thing.
	;

	\ Returns offset to use for RX buffer reading, accounting for the 16 bytes subtracted from CAPR when it is written
	: rx-read-offset ( -- offset to read from in RX buffer )
		\ We add 16 bytes here
		\ This is because the initial value of CAPR is 0xFFF0, 16 bytes below the max. 
		\ This is because you're intended to add 16 bytes to your CAPR when you read it out before you use it.
		\ Adding 16 bytes corresponds to an offset of 0 into the RX buffer (because the addition overflows/wraps)

		\ The Forth addition does not overflow here so we have to mod to pretend like it does
		\ double mod: one for 16-bit addition overflow, other for buffer size
		capr-reg reg-read2 10 + 10000 mod rx-buffer-nominal-len mod 
	;

	: set-rx-read-offset ( offset to set -- )
		3 + 3 invert and \ +3 then AND with ~3 for alignment
		rx-buffer-nominal-len 10 - mod \ Need to do the mod, this is so something like 0x8010 turns into 0x0 so that on the next step we subtract 0x16 and get 0xfff0
		10 - ffff and \ Truncate to 16 bit, if we went negative 2s complement will save us
		capr-reg reg-write2 \ write CAPR
	;

	\ Dump 256 bytes starting from the given offset in the RX buffer
	\ 8 bytes per line and it shows the starting offset of each line like hexdump
	: debug-dump-buffer ( offset -- )
		." ******START DUMP*******" cr 
		d# 32 0 do
			." 0x" dup i 8 * + .h ." :" 
			dup rx-buffer-vaddr + i 8 * + l@ .h \ First 4 bytes, i*8
			dup rx-buffer-vaddr + i 8 * 4 + + l@ .h \ Second 4 bytes, i*8 + 4
			cr
		loop
		drop \ discard offset
		." ******END DUMP*********" cr
	;

	0 instance value num-wraps
	0 instance value wrap-dump-start-offset
	0 instance value previous-capr
	0 instance value last-pkt-len

	: dump
		" dump" evaluate
	;

	
	0 instance value obp-get-block-xt
	0 instance value tftp-block-addr
	: get-tftp-block#
		\ Cache the XT for nr-get-block# so we don't have to look it up every time (slow)
		obp-tftp if
			obp-get-block-xt if
				\ obp-get-block-xt obp-tftp call-package \ SLOW, not needed if just reading a value (slow even though we have an XT cached)
				tftp-block-addr l@ \ much faster (below we used the XT to get to the memory address backing it, so this is just a vanilla memory read)
			else
				\ " nr-get-block#" obp-tftp ihandle>phandle find-method if
				" tftp-block#" obp-tftp ihandle>phandle find-method if
					dup to obp-get-block-xt
					>body to tftp-block-addr
				else
					." unable to find tftp-block# method" cr
					0
				then
			then
		else
			0
		then
	;

	0 instance value last-tftp-block

	\ Open Firmware standard read method for network device
	\ Returns actual number of bytes received or -2 if no packet is currently available
	: read ( addr len -- retval )
		\ ." PACKET READ METHOD stack is " .s cr
		\ ." CAPR " capr-reg reg-read2 .h cr
		\ ." CBR " cbr-reg reg-read2 .h cr
		\ ." ISR " isr-reg reg-read2 .h cr
		\ ." Cmd register " command-register reg-read .h cr
		\ ." RCR " recv-config-reg reg-read4 .h cr

		\ TODO/DEBUG: sleep to isolate problems/race conditions in driver
		\ d# 50 ms

		\ Check for RX overflow state and clear it
		\ This state will prevent us from receiving any new packets until it is cleared
		isr-reg reg-read2 50 and 0 > if
			\ At least one of Rx Buffer Overflow or RX FIFO overflow is active
			\ Per programming guide, we are recommended to clear all of them
			\ This is not handled at this time
			." At least one overflow interrupt is active, this is currently unhandled, RX is stopped, possible corruption! ISR = 0x" isr-reg reg-read2 .h cr
			2drop
			-2 exit \ no packet available
		then

		\ If the command register bit 1 is set, the buffer is empty and there is no packet stored
		command-register reg-read 1 and 1 = if
			should-dump if
				." No packet available, BUFE set" cr
			then
			2drop \ remove addr and len arguments from stack
			-2 exit \ return -2 for no packet available
		then

		\ Check for ROK condition in ISR, if this is not set then the packet is not done with DMA copy yet even though the "buffer empty" bit is not set
		isr-reg reg-read2 1 and 0 = if
			\ ROK is not set, the packet is not ready yet
			should-dump if
				." No packet available, ROK not set" cr
				." ISR " isr-reg reg-read2 .h cr
			then
			2drop
			-2 exit
		then

		\ DMA sync before we read
		rx-buffer-vaddr rx-buffer-baddr rx-buffer-len my-dma-sync

		\ There is a 32 bit header on the packet in the RX buffer
		\ The first 16 bits are the size of the packet and the last 16 bits are the "Receive Status Register in Rx Packet Header" per datasheet pp.10
		\ stack is currently ( dest_addr, length to read )

		\ TODO / DEBUG
		rx-read-offset to previous-capr


		\ The header is little endian
		\ The easiest thing to do is to flip it in place, since lbflips operates on a memory location, not a stack value
		\ The device has already handed us ownership of the buffer (except for the 0xFFF0 check below...) so this *should* not be a problem
		rx-read-offset rx-buffer-vaddr + 4 lbflips

		\ read packet length
		rx-read-offset rx-buffer-vaddr + w@ ( dest addr, length to read, packet length )
		\ Before we continue, we need to check if this packet is still in progress
		\ FreeBSD driver says if length is 0xfff0 this packet is not yet valid
		dup FFF0 = if
			." Found packet but it's not done DMA yet, not able to read it!" cr
			3drop \ remove dest addr, length to read, packet length
			\ Need to flip header back because we'll be checking it again
			rx-read-offset rx-buffer-vaddr + 4 lbflips
			-2 exit
		then

		( dest addr, length to read, packet length )

		\ TODO/DEBUG: check for packet length exceeding typical max we see from tcpdump for TFTP packets
		\ this would indicate client is desyncing and reading the wrong field for packet length
		dup 232 > if
			." Detected long packet length: " dup .h cr
		then

		dup to last-pkt-len

		( dest addr, length to read, packet length )

		\ Done with all checks, we are for sure going to handle this packet now.

		\ dup ." Initial RX of packet with length " .h ." stack is " .s cr
		\ Per the programming guide there is a 4 byte CRC on the end of the packet, we don't want to copy that to our caller
		4 - ( dest addr, length client wants, packet length less CRC )
		\ we will read the lesser of the packet length or the length the caller wants
		min ( addr, length we will actually read )

		\ obtain source address for memory copy: RX buffer + RX read offset + 4 bytes (skip header)
		rx-read-offset ( addr, read len, rx read offset ) rx-buffer-vaddr ( addr, read len, rx read offset, rx buffer vaddr ) + ( addr, read len, absolute read address )
		4 + ( dest addr, length we will read, src addr ) 
		-rot ( src addr, dest addr, length we will read )


		dup ( src addr, dest addr, length we will read, length we will read ) -rot ( src addr, length we will read, dest addr, length we will read ) 3 pick ( src addr, length we will read, dest addr, length we will read, src addr ) -rot ( src addr, length we will read, src addr, dest addr, length we will read )
		move \ do the copy ( src addr, length we read )
		
		\ nip \ remove extra src ( length we read )

		\ DEBUG: use the extra src addr for sanity checking the TFTP block number (comment out the nip above if using this)
		swap ( length we read, src addr )

		last-pkt-len 232 = if
			\ tftp packet
			\ read at src addr + 0x2c bytes for 2 byte word that indicates TFTP block number
			\ check this for sanity
			2c + w@ ( length we read, TFTP block number )
			\ dup last-tftp-block < if ( length we read, TFTP block number )
				\ ." Found a TFTP block number " dup .d ." less than the last known TFTP block number " last-tftp-block .d cr
				\ 0 to should-dump
			\ then
			to last-tftp-block \ store last TFTP block number
		else
			drop \ get rid of src addr
		then

		\ Set CAPR to reflect we read this packet
		\ We need to detect if this packet was in the wrap area "past" the end of the buffer

		rx-read-offset 10 - 80 - 0 max to wrap-dump-start-offset

		\ First read the length of the packet again
		rx-read-offset rx-buffer-vaddr + w@ ( length we read, packet length )
		dup rx-read-offset + 4 + ( length we read, packet length, offset into RX buffer of end of packet accounting for extra 4 bytes for header -- length already includes CRC )
		\ It seems like the card doesn't consider the "+ 16 byte" in the RX buffer size when computing wrap amount for purposes of offset
		\ Instead it goes based on the nominal nominal size (32K), so compute our wrap amount the same way it does
		rx-buffer-nominal-len 10 - - dup 0 >= if ( length we read, packet length, overrun/wrap amount )
			\ Packet length caused us to exceed buffer
			\ CAPR = 0 + overrun amount + alignment stuff
			nip \ we don't care about packet length in this case ( length we read, overrun/wrap amount )

			set-rx-read-offset \ Overrun amount is on the stack, this is the base for new CAPR (it already includes the 4 byte header)
			
			\ TODO/DEBUG: log the computed start address for the wraparound packet after 42 buffer wraps
			\ We seem to run into trouble around 45
			num-wraps 1 + to num-wraps
			num-wraps d# 46 > if
				\ ." Wrap: " num-wraps .d ." start address: (0x10 less than real): " rx-read-offset .h cr
				\ rx-read-offset 10 - 80 - 0 max to wrap-dump-start-offset \ set start offset for dumps
				\ 0 to should-dump \ dump the buffer area of interest for the next 2 packets received
			then
		else
			\ we didn't overrun so we don't care about overrun amount
			drop ( length we read, packet length )
			\ RxReadOffset = RxReadOffset + packet length + alignment stuff

			\ Note we STILL NEED the +4 for header here because we're dealing with the packet length, not the overrun amount!
			rx-read-offset + 4 + set-rx-read-offset \ CAPR + packet length + 4 for header is then new offset, set-rx-read-offset handles the rest

			\ TODO/DEBUG: dump buffer start so we can see if wraps are aligning with what we expect
			\ should-dump 0 > if
			\	wrap-dump-start-offset debug-dump-buffer
			\	should-dump 1 - to should-dump
			\ then
		then

		\ TODO/DEBUG: Dump CAPRs after TFTP block 5900 (where we see problems)
		\ Also note every 100 TFTP blocks so we can see progress
		get-tftp-block# d# 100 mod 0 = if
			." TFTP block " get-tftp-block# .d cr
		then
		
		\ get-tftp-block# d# 8280 > if
		\  	1 to should-dump
		\ then

		should-dump 0 > if
			." Previous CAPR 0x" previous-capr .h ." Packet length 0x" last-pkt-len .h ." Next CAPR 0x" rx-read-offset .h cr
			." Received TFTP block " last-tftp-block .d cr
			\ get-tftp-block# d# 8115 > if
			\	wrap-dump-start-offset debug-dump-buffer
			\ then
			\ " dev /memory .properties" evaluate \ check allocated memory
		then

		\ Stack is now ( length we read )


		\ Determine whether to clear RXOK interrupt
		\ It's possible that we received another packet before RXOK was cleared, so we don't want to clear it (which would make us not handle the next packet) if there might be another packet waiting
		\ command-register reg-read 1 and 1 = if \ check if BUFE is set, doesn't work
		cbr-reg reg-read2 8000 mod rx-read-offset = if \ CBR (mod 8000 since it seems to alternate between being 0x8000 ahead of CAPR and not) is equal to CAPR (adjusted)
			\ we can clear RXOK without problems
			isr-reg reg-read2 1 or isr-reg reg-write2
		else
			should-dump 0 > if
				." Not clearing RXOK: CBR = 0x" cbr-reg reg-read2 .h cr
			then
		then

		\ Dump buffer for short packets (check if this is what's causing us to exit with load-size too small)
		\ last-pkt-len 232 < last-tftp-block 5 > and if
		\	." Received packet less than 0x232 long! Dump..." cr
		\	wrap-dump-start-offset debug-dump-buffer
		\ then

		\ Return out the length actually received
		\ dup ." RX return we read length " .h cr
	;

	0 value did-allocate-extra-space

	\ Open Firmware standard load function for bootable network device
	\ Uses obp-tftp
	: load
		\ HORRIBLE HORRIBLE HACK
		\ Default OF shared load implementation doesn't allocate enough space (4 MiB) to load mach.macosx.mkext (7.7 MiB) during Mac OS X boot
		\ Allocate a bunch of space right after the space it allocates so that we have one contiguous mapped area for the load to go
		\ This is the last thing we need to load before booting into Mac OS X (which will take over the memory map) so it's OK that nobody ever deallocates the extra space
		\ TODO: Probably move this into a custom CHRP boot script that runs before BootX, that would be cleanest/most realistic
		did-allocate-extra-space 0 = if
			\ Claim 8 MiB of physical memory at 4 MiB after load-base (total 12 MiB)
			" dev /memory load-base 400000 + 800000 0 claim" evaluate drop
			\ Map this memory 1:1 to a virtual address (so it's both physically and virtually contiguous with the default 4 MiB)
			" dev /cpus/@0 load-base 400000 + dup 800000 10 map" evaluate
			1 to did-allocate-extra-space
		then
		." Allocated memory at the beginning of load" cr
		" dev pci1/@d/@4" evaluate
		" load" obp-tftp $call-method
	;


fcode-end