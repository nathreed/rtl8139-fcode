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
	20 constant tx-descriptor-0-start-reg
	d# 34320 constant rx-buffer-len
	30 constant rx-buffer-reg
	44 constant recv-config-reg
	38 constant capr-reg \ Current Address of Packet Read (where we will start reading in the RX buffer next time we RX. 2-byte register)
	d# 1500 constant mtu \ Ethernet packet payload max MTU is 1500 bytes per standard
	10 constant tx-descriptor-0-status-reg
	64 constant tx-delay-ms \ 100ms for TX delay
	3a constant cbr-reg \ Current Buffer Address (where the device is writing in the RX buffer. 2-byte register)
	rx-buffer-len d# 1536 - constant rx-buffer-nominal-len \ Nominal length of RX buffer (ignoring 1.5K allocated for wrap overrun). Used to determine overrun amount for handling wrap behavior.

	\ Instance values for RTL8139 driver
	0 instance value op-regs-base \ base virtual address for RTL8139 operational registers, mapped in during open function
	0 instance value tx-descriptor-vaddr \ virtual address for TX descriptor 0 (1600 bytes)
	0 instance value tx-descriptor-baddr \ bus address for TX descriptor 0 (1600 bytes)
	0 instance value rx-buffer-vaddr \ virtual address for RX buffer (34320 bytes)
	0 instance value rx-buffer-baddr \ bus address for RX buffer (34320 bytes)
	0 instance value mac-buffer-addr \ address of 8-byte buffer to store MAC address (this feels silly but done in the interest of expediency to get an address that will work with encode-bytes) 
	0 instance value last-rx-wrap-len \ the number of bytes past the nominal length of the RX buffer the last received packet overran. Used to compute offset of next packet from top of RX buffer. See datasheet pp17 for WRAP behavior.
	0 instance value obp-tftp \ ihandle of TFTP boot package

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
	: setup-tx
		\ Enable transmit state machine (datasheet pp12 command register)
		command-register reg-read 4 or command-register reg-write
		\ Allocate DMA memory for Tx Descriptor 0 (we will only support utilizing one Tx descriptor at a time)
		\ This is not allowed to be more than 1792 bytes and we will probably be sending regular 1500 byte packets at max anyway
		\ 1600 bytes should be fine
		tx-descriptor-len " dma-alloc" $call-parent to tx-descriptor-vaddr \ Allocate 1600 bytes of memory for DMA

		\ Zero allocated memory to prevent issues
		tx-descriptor-vaddr tx-descriptor-len erase

		\ TEMP: write sentinel values where the destination MAC address would go
		1 tx-descriptor-vaddr 1 + c!
		2 tx-descriptor-vaddr 2 + c!
		3 tx-descriptor-vaddr 3 + c!
		4 tx-descriptor-vaddr 4 + c!
		5 tx-descriptor-vaddr 5 + c!

		\ Program start bus address into Tx Start Address Desc 0 register (0x20-0x23 4-byte write)
		\ Obtain and store bus address
		tx-descriptor-vaddr tx-descriptor-len false " dma-map-in" $call-parent to tx-descriptor-baddr
		\ Program Tx Start Address Desc 0 register with bus address
		tx-descriptor-baddr tx-descriptor-0-start-reg reg-write4

		
	;

	\ Basic setup for RX operation (DMA allocation, receive configuration)
	: setup-rx
		\ Enable receive state machine (datasheet pp12 command register)
		command-register reg-read 8 or command-register reg-write
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

		\ Set early Rx thresholds, Rx buffer length, and wrap mode in Receive Configuration Register (datasheet pp16)
		\ RCR contents will be 0xF692
		\ no early RX threshold,
		\ no multiple early interrupt,
		\ only accept 64-byte error packets,
		\ Rx FIFO threshold none (DMA when whole packet received),
		\ 32K Rx buffer,
		\ max DMA burst 1024 bytes,
		\ wrap mode enabled,
		\ do not accept error,
		\ accept runt packets,
		\ do not accept broadcast or multicast packets,
		\ accept physical match,
		\ do not accept all packets)
		F692 recv-config-reg reg-write4 \ RCR is 0x44-0x47 4 byte register

		\ Reset CAPR (current address of packet read) register (0x38 2 byte register)
		0 capr-reg reg-write2
	;

	\ Read the MAC address from the device and expose the mac-address property required by Open Firmware for network devices
	: setup-mac-addr ( -- )
		8 alloc-mem to mac-buffer-addr \ Allocate 8 bytes for MAC address buffer (we need this for encode-bytes)
		0 reg-read4 \ read first 4 bytes of MAC address
		mac-buffer-addr rl! \ store these 4 bytes to the first 4 bytes of the buffer
		4 reg-read2 \ read last 2 bytes of MAC address
		mac-buffer-addr 4 + rw! \ store these 2 bytes to the last 2 bytes of the buffer
		mac-buffer-addr 6 encode-bytes " mac-address" property \ expose mac-address property with encoded bytes
		mac-buffer-addr 6 encode-bytes " local-mac-address" property \ expose local-mac-address property as well (optional)
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
		\ Unmap and free DMA memory
		tx-descriptor-baddr tx-descriptor-len " dma-map-out" $call-parent \ unmap DMA
		tx-descriptor-vaddr tx-descriptor-len " dma-free" $call-parent 
		rx-buffer-baddr rx-buffer-len " dma-map-out" $call-parent
		rx-buffer-vaddr rx-buffer-len " dma-free" $call-parent 
		mac-buffer-addr 8 free-mem \ MAC buffer

		obp-tftp ?dup if close-package then
	;


	\ Open Firmware standard open function, get the device ready for use
	: open
		\ Start with fresh line for any output we produce
		cr
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

		" RTL,8139" device-name
		" network" device-type
		" ethernet" encode-string " network-type" property
		" network" encode-string " removable" property
		" net" encode-string " category" property

		\ obp-tftp init for booting
		init-obp-tftp 0= if close false exit then

		\ return true for successful open
		true
	;

	\ Open Firmware standard write method for network device, returns actual number of bytes written
	\ Packet must be complete with all addressing information, including source hardware address
	: write ( src-addr len -- actual )
		dup mtu > if \ duplicate the length so we can use it again then make sure it's not greater than MTU
			." RTL8139: Attempted to write data exceeding one MTU, this is not implemented!" cr
			0 exit \ Return 0 bytes actually written
		then

		\ 1. (src-addr, len, len) 2. (len, len, src-addr) 3. (len, len, src-addr, dest-addr) 4. (len, src-addr, dest-addr, len)
		dup rot tx-descriptor-vaddr rot \ make the arguments how we need for the move
		\ Copy the memory into the Tx descriptor
		move \ perform the memory copy, stack is now (len)

		\ Flush caches for DMA
		tx-descriptor-vaddr tx-descriptor-baddr tx-descriptor-len my-dma-sync

		\ Tell the device the size and give it the ownership of the TX buffer (one operation)
		dup ( len, len )
		tx-descriptor-0-status-reg reg-write2 \ stack is now (len), write data to TX descriptor 0 register. This is the size and then we also set OWN bit to 0, handing ownership of the buffer to the device

		\ Check bit 15 for TX completion
		\ Completion must happen within 10ms
		tx-delay-ms 0 do
			1 ms \ delay
			tx-descriptor-0-status-reg reg-read2 8000 and \ check bit 15
			0 = if leave then
		loop

		\ Verify we have completion
		tx-descriptor-0-status-reg reg-read2 8000 and
		0 > if
			." Transmitted packet." cr
			tx-descriptor-0-status-reg reg-read2 .h cr
		else
			." Packet did not transmit in time!" cr
			\ Output tx descriptor 0 status reg for debug purposes
			tx-descriptor-0-status-reg reg-read2 .h cr
			0 exit
		then

		\ len is still on the stack; we return it because we have written the whole thing.
	;

	\ Open Firmware standard read method for network device
	\ Returns actual number of bytes received or -2 if no packet is currently available
	: read ( addr len -- retval )
		\ If CAPR != CBR, there is a packet ready for us to receive, if not, there is no packet
		capr-reg reg-read2 cbr-reg reg-read2 = if
			." No packet available" cr
			2drop \ remove addr and len arguments from stack
			-2 exit \ return -2 for no packet available
		then

		\ Determine the length of the packet
		\ We start by fetching the 2-byte value from the Ethernet frame header that is either the length or the EtherType
		capr-reg reg-read2 \ Get the offset into the RX buffer where the next packet starts
		dup \ Save CAPR value for use when handling length, stack is now (addr, len, capr value, capr value)
		rx-buffer-vaddr + c + w@ \ Fetch the 2-byte value from the RX buffer start address offset by the CAPR value + 12 for offset of length field
		\ stack is now (addr, len, capr value, ethernet frame length)
		dup d# 1536 < if ( addr, len, capr value, ethernet frame length )
			\ This is a length value
			\ Compute and save overrun amount (if any)
			dup rot \ Save frame length for use after if statement ( addr, len, ethernet frame length, capr value, ethernet frame length )
			+ ( addr, len, ethernet frame length, offset of first byte past end of packet )
			rx-buffer-nominal-len - \ compute end offset - nominal length = overrun amount ( addr, len, frame length, overrun amount)
			0 max \ Compute overrun amount, negative overrun means we did not overrun so we clamp to 0
			dup ." Overrun is " s. cr
			to last-rx-wrap-len \ ( addr, len, frame length ) - NOTE that in theory we could have this on the stack since we only use it later on in this function but that makes the stack a lot more complex
		else
			\ This is an EtherType value
			." EtherType packet RX not yet implemented" cr
			0800 = if
				." IPv4 EtherType" cr
			else 0806 = if
				." ARP EtherType" cr then
			then
		then

		\ Flush caches for DMA before we read
		rx-buffer-vaddr rx-buffer-baddr rx-buffer-len my-dma-sync

		\ Now we know the length
		\ Copy the bytes the caller has requested. Ensure we only copy the lesser of what was requested and what we have available.
		\ Stack is currently ( addr, len, frame length )
		min ( addr, length to transfer )
		\ Starting address of the ethernet frame (previously we added 12 to get the length field)
		capr-reg reg-read2 rx-buffer-vaddr + w@ rot ( src_addr, dest_addr, length to transfer )
		dup rot swap 3 pick rot swap ( src, length to transfer , src, dest, length to transfer )
		move \ do the copy
		nip \ remove extra src ( length to transfer )

		\ Set CAPR to reflect that we processed the packet we know about
		last-rx-wrap-len 0 > if
			\ We had an overrun, new CAPR is beginning of buffer + overrun amount
			rx-buffer-vaddr last-rx-wrap-len + capr-reg reg-write2 ( length to transfer )
			\ overrun amount will be reset next time we read
		else
			\ New CAPR is old CAPR plus frame length
			\ Note we have to read frame length from memory again because the length we have on the stack now is the length to transfer
			\ If client requested less we wouldn't advance CAPR by enough.
			capr-reg reg-read2 rx-buffer-vaddr + c + w@ \ read frame length from beginning of frame (length to transfer, full frame length)
			capr-reg reg-read2 + capr-reg reg-write2 \ add full frame length to current CAPR value and return ( length to transfer)
		then

		\ Stack is still (length actually received)
		\ Return out the length actually received
	;

	\ Open Firmware standard load function for bootable network device
	\ Uses obp-tftp
	: load
		" load" obp-tftp $call-method
	;


fcode-end