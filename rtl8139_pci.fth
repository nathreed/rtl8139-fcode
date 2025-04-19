\ Wrapper to make PCI FCode ROM from main RTL8139 driver
\ Used to allow main FCode to stand alone (required for USB loading in Apple OF)
\ realtek vendor id, 8139 device ID, class code 020000 (network controller/ethernet controller)
tokenizer[ hex 10ec 8139 020000 pci-header ]tokenizer
fload rtl8139.fth
\ Expose basic properties: name and reg
\ reg property
\ we will expose configuration space and BAR1 (operational registers memory space)
\ BAR0 is the same view into the operational registers but in I/O space. We don't care about it and won't expose in alternate-reg either
\
\ CONFIGURATION SPACE
my-address my-space encode-phys 	\ configuration space base
0 encode-int encode+ 				\ encode first 0 of size and append to property value array we are building
0 encode-int encode+ 				\ second 0 of size and append to property value array
\ BAR1 (Memory Space)
my-address
my-space 02000014 or				\ OR the data into place to describe Memory Space BAR and 0x14 offset (BAR1 location in config space)
encode-phys encode+					\ encode address and append to property value array
0 encode-int encode+				\ high 32 bits of size
0100 encode-int encode+				\ low 32 bits of size (256 bytes)
" reg" property						\ finally produce the reg property with the value array we have been building

\ name property
" ethernet" encode-string			\ encode the string "ethernet" to use as the name (ref. PCI Binding to OF p.9 line 36)
" name" property

." reg and name defined!" cr
pci-end