"""
mkext format salient details
details paraphrased from 10.6.8 libkern/mkext.h which has doc comments while the 10.5 and earlier versions (which are in libsa, not libkern) don't.
FILE STRUCTURE
1. Core header comprising
	a. magic ("MKXT")
	b. signature/magic pt2 ("MOSX")
	c. length in bytes of the whole file, including the header (4 bytes unsigned)
	d. adler32 checksum of the remainder of the file starting with the version field (next field) (4 bytes)
	e. version of the file. This program only handles creating v1 format files so this will be hardcoded for the v1 version string (4 bytes)
	f. the number of kexts included in the file (4 bytes unsigned)
	g. cputype value (4 bytes) - 0xffffffff for PPC32 from OSX 10.2 Extensions.mkext
	h. cpusubtype value (4 bytes) - 0xffffffff for PPC32 from OSX 10.2 Extensions.mkext
2. File table: Array of kext entries (count of array specified in header) with each kext entry having the following structure
	a. mkext_file entry for the Info.plist file
	b. mkext_file entry for the module itself
3. Optionally compressed file data, located at the offsets given in the mkext_file entries in the file table.

mkext_file entry is defined as follows:
	a. offset into the mkext file (whole file, includes header) at which the data starts (4 bytes)
	b. compressed size of this file. In v1, files are compressed with LZSS. If the compressed size is 0, it indicates that the file is uncompressed. (4 bytes)
	c. real (uncompressed) size of this file (4 bytes)
	d. last modified timestamp of this file (4 bytes) - cast to time_t / unix epoch seconds
"""

import sys
import os

OSX_LAST_MODIFIED = b'\x3d\x48\x97\x95' # last modified date found in OSX mkext -- 8/2002

def adler32(buffer): # from ChatGPT (asked it to convert C code from xnu to python)
    MOD_ADLER = 65521
    low_half = 1
    high_half = 0

    for cnt, byte in enumerate(buffer):
        if cnt % 5000 == 0:
            low_half %= MOD_ADLER
            high_half %= MOD_ADLER

        low_half += byte
        high_half += low_half

    low_half %= MOD_ADLER
    high_half %= MOD_ADLER

    result = (high_half << 16) | low_half
    return result


def make_mkext(kext_path): # not from ChatGPT (my own)
	info_plist_path = os.path.join(kext_path, "Contents", "Info.plist")
	module_path = os.path.join(kext_path, "Contents", "MacOS", os.path.basename(kext_path).split(".")[0])

	info_plist_len = os.path.getsize(info_plist_path)
	module_len = os.path.getsize(module_path)

	with open(info_plist_path, "rb") as info_plist_file:
		with open(module_path, "rb") as module_file:
			with open("out.mkext", "w+b") as outfile:
				# Magic 
				magic = "MKXTMOSX".encode("ascii") # don't include null terminator
				outfile.write(magic)
				# File length
				# We assume no compression so we can compute this now and just sum the file lengths
				length = info_plist_len + module_len + 32 + 32 # file lengths, 32 bytes for file table, 32 bytes for core header
				outfile.write(length.to_bytes(4, "big"))
				# We will have to come back to the checksum later once everything has been written
				outfile.seek(4, 1) # 4 bytes relative to current
				# Version, hardcoded for v1
				outfile.write(b'\x01\x00\x80\x00')
				# number of kexts included in the file (hardcoded to 1)
				outfile.write(int(1).to_bytes(4, "big"))
				# cputype and subtype (hardcoded 0xffffffff for PPC32 - observed value)
				outfile.write(b'\xff\xff\xff\xff')
				outfile.write(b'\xff\xff\xff\xff')
				# File table
				# Info.plist
				# Offset for Info.plist start: 64 bytes (after header & file table)
				outfile.write(int(64).to_bytes(4, "big"))
				# compressed size 0 indicating no compression
				outfile.write(int(0).to_bytes(4, "big"))
				# actual size of Info.plist
				outfile.write(info_plist_len.to_bytes(4, "big"))
				# last modified timestamp
				outfile.write(OSX_LAST_MODIFIED)
				# Actual module file
				# Offset for the module: 64 bytes (header & file table) + length of Info.plist
				module_offset = 64 + info_plist_len
				outfile.write(module_offset.to_bytes(4, "big"))
				# Compressed size 0 indicating no compression
				outfile.write(int(0).to_bytes(4, "big")) 
				# Actual size of module file
				outfile.write(module_len.to_bytes(4, "big"))
				# last modified timestamp
				outfile.write(OSX_LAST_MODIFIED)
				# Write the files
				outfile.write(info_plist_file.read())
				outfile.write(module_file.read())

				# Now we need the adler32
				# seek to the offset of version (16), read the whole file from there, and compute the adler32
				outfile.seek(16, 0)
				file_data = outfile.read()
				adler_sum = adler32(file_data)
				# Write the adler32 where it belongs
				outfile.seek(12, 0)
				outfile.write(adler_sum.to_bytes(4, "big"))

if __name__ == '__main__':
	kext_path = sys.argv[1]
	make_mkext(kext_path)