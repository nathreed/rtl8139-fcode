\ Main RTL8139 driver
fcode-version3
	hex
	external \ ensure all functions defined here are visible externally after execution has completed

	\ See file for details, Apple Open Firmware broken for map-in
	fload apple_workaround.fth

	\ Instance values for RTL8139 driver
	0 instance value op-regs-base \ base virtual address for RTL8139 operational registers, mapped in during open function
	0 instance value tx-descriptor-vaddr \ virtual address for TX descriptor 0 (1600 bytes)
	0 instance value tx-descriptor-baddr \ bus address for TX descriptor 0 (1600 bytes)
	0 instance value rx-buffer-vaddr \ virtual address for RX buffer (34320 bytes)
	0 instance value rx-buffer-baddr \ bus address for RX buffer (34320 bytes)

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

	\ Perform a software reset of the RTL8139
	\ see datasheet pp12
	: sw-reset ( -- )
		37 reg-read \ read current value from command register 0x37
		10 or \ set bit 4 (reset)
		37 reg-write \ write modified value to command register 0x37

		\ Wait for RTL8139 to clear reset bit 4 indicating it has completed reset
		\ Will wait max of 10ms for reset to occur
		10 0 do
			1 ms \ delay
			37 reg-read 10 and \ Read command register and mask out all bit the reset bit 4 ( -- byte)
			0 = if leave then \ exit loop if reset bit is cleared ( -- )
		loop

		\ Verify reset has completed
		37 reg-read 10 and \ Read register and check bit 4 ( -- register value)
		0 = if
			." RTL8139 SW reset completed" cr
		else
			." RTL8139 SW reset not completed in allowed time!" cr
		then
	;

	\ Basic setup for TX operation (DMA allocation, transmit configuration)
	: setup-tx
		\ Enable transmit state machine (datasheet pp12 command register)
		37 reg-read 4 or 37 reg-write
		\ Allocate DMA memory for Tx Descriptor 0 (we will only support utilizing one Tx descriptor at a time)
		\ This is not allowed to be more than 1792 bytes and we will probably be sending regular 1500 byte packets at max anyway
		\ 1600 bytes should be fine
		640 " dma-alloc" $call-parent to tx-descriptor-vaddr \ Allocate 1600 bytes of memory for DMA

		\ Program start bus address into Tx Start Address Desc 0 register (0x20-0x23 4-byte write)
		\ Obtain and store bus address
		tx-descriptor-vaddr 640 false " dma-map-in" $call-parent to tx-descriptor-baddr
		\ Program Tx Start Address Desc 0 register with bus address
		tx-descriptor-baddr 20 reg-write4

		
	;

	\ Basic setup for RX operation (DMA allocation, receive configuration)
	: setup-rx
		\ Enable receive state machine (datasheet pp12 command register)
		37 reg-read 8 or 37 reg-write
		\ Allocate DMA memory for Rx buffer
		\ Rx buffer will be 32K but we want to use wrapping. Total size will be 32K + 16 byte + 1536 bytes = 0x8610 bytes (34320 bytes)
		8610 " dma-alloc" $call-parent to rx-buffer-vaddr

		\ Program Rx buffer start address register
		\ Obtain bus address first
		rx-buffer-vaddr 8610 false " dma-map-in" $call-parent to rx-buffer-baddr
		\ Tell device about it (register 0x30-0x33 4 byte address)
		rx-buffer-baddr 30 reg-write4

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
		F692 44 reg-write4 \ RCR is 0x44-0x47 4 byte register

		\ Reset CAPR (current address of packet read) register (0x38 2 byte register)
		0 38 reg-write2
	;


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
		0100 " map-in" $call-parent to op-regs-base
		
		\ Perform SW reset to get RTL8139 ready for use
		sw-reset
		
		\ We do not need to enable autonegotiation by default...it is enabled by default (loaded from EEPROM)

		\ Setup for TX/RX operations - DMA allocation, configuration register programming, etc
		setup-tx
		setup-rx

		\ return true for successful open
		true
	;

	: close
		\ Unmap operational register base address
		op-regs-base 0100 " map-out" $call-parent
		\ Disable memory space access and bus mastering
		0 my-space 04 + " config-w!" $call-parent \ write 0 to command register (04)
		\ Unmap and free DMA memory
		tx-descriptor-baddr 640 " dma-map-out" $call-parent \ unmap DMA
		tx-descriptor-vaddr 640 " dma-free" $call-parent \ 1600 bytes was the initial allocation
		rx-buffer-baddr 8610 " dma-map-out" $call-parent
		rx-buffer-vaddr 8610 " dma-free" $call-parent \ 34320 bytes initial allocation
	;
fcode-end