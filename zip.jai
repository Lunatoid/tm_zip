
#import "File";
#import "Math";

Compression_Method :: enum u16 {
    STORE   :: 0;
    DEFLATE :: 8;
    LZMA    :: 14;
}

Zip :: struct {
    entries: [..] Zip_Entry;

    eocd: EOCD;
    central_dirs: [..] Central_Dir;
    local_files: [..] Local_File;

    file: string;
}

Zip_Entry :: struct {
    name: string;
    is_compressed: bool;
    is_encrypted: bool;
    uncompressed_size: u64;
    compressed_size: u64;
}

zip_load :: (name: string) -> Zip, bool {
    file, file_success := read_entire_file(name);
    if !file_success return .{}, false;

    zip, success := zip_load_memory(file);
    return zip, success;
}

zip_free :: (zip: *Zip) {
    array_free(zip.entries);
    array_free(zip.central_dirs);
    array_free(zip.local_files);
}

zip_load_memory :: (file: string) -> Zip, bool {
    zip: Zip;
    zip.file = file;

    stream := mem_open(cast([] u8) zip.file);

    mem_seek(*stream, -EOCD_LENGTH, .END);

    // Search for the EOCD from the back...
    // Profile this cause it seems like it would be slow
    while mem_can_read(*stream) {
        magic: u32;
        mem_read(*stream, *magic);
        if magic == EOCD_MAGIC break;
        mem_seek(*stream, -5, .CURRENT);
    }

    if !read_eocd(*stream, *zip.eocd) {
        zip_free(*zip);
        return .{}, false;
    }

    is_zip64 := zip.eocd.central_dir_offset == U32_MAX;
    central_dir_offset := ifx is_zip64 then zip.eocd.eocd64.central_dir_offset else zip.eocd.central_dir_offset;
    mem_seek(*stream, xx central_dir_offset, .START);

    for 0..zip.eocd.central_dir_count-1 {
        central_dir := array_add(*zip.central_dirs);
        if !read_central_dir(*stream, central_dir) {
            zip_free(*zip);
            return .{}, false;
        }
    }

    for zip.central_dirs {
        mem_seek(*stream, it.local_file_header_offset, .START);
        local_file := array_add(*zip.local_files);

        if !read_local_file(*stream, local_file) {
            zip_free(*zip);
            return .{}, false;
        }

        entry := array_add(*zip.entries);
        entry.name = local_file.file_name;
        entry.is_compressed = local_file.compression_method != .STORE;
        entry.is_encrypted = xx (local_file.general_bitflag & .ENCRYPTED);
        entry.uncompressed_size = local_file.uncompressed_size;
        entry.compressed_size = local_file.compressed_size;
    }

    return zip, true;
}

zip_extract_to_file :: (zip: *Zip, name: string, output_path: string) -> bool {
    bytes: string;
    defer free(bytes);

    success := zip_extract(zip, name, *bytes);

    if success write_entire_file(output_path, bytes);
    return success;
}

zip_extract :: (zip: *Zip, name: string, output: *string, allocator: Allocator = .{}) -> bool {
    bytes: [..] u8;

    entry: *Local_File = null;
    for * zip.local_files {
        if it.file_name == name {
            entry = it;
            break;
        }
    }

    if !entry return false;

    return extract_local_file(zip, entry, output, allocator);
}

zip_has_entry :: (zip: *Zip, name: string) -> bool {
    for zip.entries {
        if it.name == name return true;
    }
    return false;
}

#scope_file

// For zlib/deflate
#import "stb_image";

LOCAL_FILE_MAGIC: u32: 0x04034b50;
CENTRAL_DIR_MAGIC: u32: 0x02014b50;
EOCD_MAGIC: u32: 0x06054b50;
EOCD64_MAGIC: u32: 0x06064b50;
ZIP64_LOCATOR_MAGIC: u32: 0x07064b50;

Extra_Field_ID :: enum u16 {
    ZIP64_EXTRA_HEADER :: 0x0001;
    EXTENDED_TIMESTAMP :: 0x5455;
    UNIX_OWNER         :: 0x7875;
    UNICODE_PATH       :: 0x7075;
    NTFS               :: 0x000a;
}

General_Bit :: enum_flags u16 {
    ENCRYPTED         :: 0x0;
    DATA_DESCRIPTOR   :: 0x3;
    LANGUAGE_ENCODING :: 0x11;
}

Local_File :: struct {
    version: u16;
    general_bitflag: General_Bit;
    compression_method: Compression_Method;
    last_mod_time: u16;
    last_mod_date: u16;
    crc32: u32;
    compressed_size: u64;
    uncompressed_size: u64;
    file_name_length: u16;
    extra_field_length: u16;

    file_name: string;
    extra_field: [..] u8;
    data_start: u64;
}

EOCD64_Locator :: struct {
    eocd64_disk: u32;
    eocd64_offset: u64;
    disk_count: u32;
}

EOCD64 :: struct {
    eocd64_size: u64;
    created_version: u16;
    extract_version: u16;
    current_disk: u32;
    central_dir_start_disk: u32;
    central_dir_count: u64;
    central_dir_global_count: u64;
    central_dir_byte_count: u64;
    central_dir_offset: u64;

    comment: string;
}

EOCD_LENGTH :: 22;

EOCD :: struct {
    disk_number: u16;
    central_dir_start_disk: u16;
    disk_central_dir_count: u16;
    central_dir_count: u16;
    central_dir_byte_count: u32;
    central_dir_offset: u32;
    comment_length: u16;

    comment: string;
    locator: EOCD64_Locator;
    eocd64: EOCD64;
}

Central_Dir :: struct {
    created_version: u16;
    extract_version: u16;
    general_bitflag: u16;
    compression_method: Compression_Method;
    last_mod_time: u16;
    last_mod_date: u16;
    crc32: u32;
    compressed_size: u64;
    uncompressed_size: u64;
    file_name_length: u16;
    extra_field_length: u16;
    comment_length: u16;
    file_start_disk_number: u16;
    internal_file_attributes: u16;
    external_file_attributes: u32;
    local_file_header_offset: u32;

    file_name: string;
    comment: string;
    extra_field: [..] u8;
}

read_local_file :: (stream: *Memory_Stream, local_file: *Local_File) -> bool {
    magic: u32;
    mem_read(stream, *magic);

    if magic != LOCAL_FILE_MAGIC {
        mem_seek(stream, -size_of(u32), .CURRENT);
        return false;
    }

    mem_read(stream, *local_file.version);
    mem_read(stream, *local_file.general_bitflag);
    mem_read(stream, *local_file.compression_method);
    mem_read(stream, *local_file.last_mod_time);
    mem_read(stream, *local_file.last_mod_date);
    mem_read(stream, *local_file.crc32);

    compressed_size: u32;
    uncompressed_size: u32;

    mem_read(stream, *compressed_size);
    mem_read(stream, *uncompressed_size);

    local_file.compressed_size = compressed_size;
    local_file.uncompressed_size = uncompressed_size;

    mem_read(stream, *local_file.file_name_length);
    mem_read(stream, *local_file.extra_field_length);

    local_file.file_name.count = local_file.file_name_length;
    local_file.file_name.data = mem_current_data(stream);
    mem_seek(stream, local_file.file_name_length, .CURRENT);

    local_file.extra_field.count = local_file.extra_field_length;
    local_file.extra_field.data = mem_current_data(stream);
    mem_seek(stream, local_file.extra_field_length, .CURRENT);

    extra_field := mem_open(local_file.extra_field);

    while mem_can_read(*extra_field) {
        id: Extra_Field_ID;
        length: u16;
        mem_read(*extra_field, *id);
        mem_read(*extra_field, *length);

        if #complete id == {
            case .ZIP64_EXTRA_HEADER;
                if uncompressed_size == U32_MAX mem_read(*extra_field, *local_file.uncompressed_size);
                if compressed_size == U32_MAX mem_read(*extra_field, *local_file.compressed_size);
                continue;

            case .UNICODE_PATH;
                version: u8;
                mem_read(*extra_field, *version);
                assert(version == 1);
                crc32: u32;
                mem_read(*extra_field, *crc32);

                name_length := length - 5; // we read 5 bytes so far

                local_file.file_name.count = name_length;
                local_file.file_name.data = mem_current_data(*extra_field);
                mem_seek(*extra_field, name_length, .CURRENT);
                continue;


            // Recognized but unhandled
            case .EXTENDED_TIMESTAMP;
            case .UNIX_OWNER;
            case .NTFS;

            case;
                print("Zip: unrecognized extra field 0x%", formatInt(cast(int) id, 16, 4));
        }

        // If we're here we didn't handle the extra field. Skip.
        mem_seek(*extra_field, length, .CURRENT);
    }

    local_file.data_start = xx mem_current_position(stream);
    return true;
}

read_central_dir :: (stream: *Memory_Stream, central_dir: *Central_Dir) -> bool {
    magic: u32;
    mem_read(stream, *magic);

    if magic != CENTRAL_DIR_MAGIC {
        mem_seek(stream, -size_of(u32), .CURRENT);
        return false;
    }

    mem_read(stream, *central_dir.created_version);
    mem_read(stream, *central_dir.extract_version);
    mem_read(stream, *central_dir.general_bitflag);
    mem_read(stream, *central_dir.compression_method);
    mem_read(stream, *central_dir.last_mod_time);
    mem_read(stream, *central_dir.last_mod_date);
    mem_read(stream, *central_dir.crc32);

    compressed_size: u32;
    uncompressed_size: u32;

    mem_read(stream, *compressed_size);
    mem_read(stream, *uncompressed_size);

    central_dir.compressed_size = compressed_size;
    central_dir.uncompressed_size = uncompressed_size;

    mem_read(stream, *central_dir.file_name_length);
    mem_read(stream, *central_dir.extra_field_length);
    mem_read(stream, *central_dir.comment_length);
    mem_read(stream, *central_dir.file_start_disk_number);
    mem_read(stream, *central_dir.internal_file_attributes);
    mem_read(stream, *central_dir.external_file_attributes);
    mem_read(stream, *central_dir.local_file_header_offset);

    central_dir.file_name.count = central_dir.file_name_length;
    central_dir.file_name.data = mem_current_data(stream);
    mem_seek(stream, central_dir.file_name_length, .CURRENT);

    central_dir.extra_field.count = central_dir.extra_field_length;
    central_dir.extra_field.data = mem_current_data(stream);
    mem_seek(stream, central_dir.extra_field_length, .CURRENT);

    central_dir.comment.count = central_dir.comment_length;
    central_dir.comment.data = mem_current_data(stream);
    mem_seek(stream, central_dir.comment_length, .CURRENT);

    extra_field := mem_open(central_dir.extra_field);

    while mem_can_read(*extra_field) {
        id: Extra_Field_ID;
        length: u16;
        mem_read(*extra_field, *id);
        mem_read(*extra_field, *length);

        if #complete id == {
            case .ZIP64_EXTRA_HEADER;
                if uncompressed_size == U32_MAX {
                    mem_read(*extra_field, *central_dir.uncompressed_size);
                }

                if compressed_size == U32_MAX {
                    mem_read(*extra_field, *central_dir.compressed_size);
                }

            case .UNICODE_PATH;
                version: u8;
                mem_read(*extra_field, *version);
                assert(version == 1);
                crc32: u32;
                mem_read(*extra_field, *crc32);

                name_length := length - 5; // we read 5 bytes so far

                central_dir.file_name.count = name_length;
                central_dir.file_name.data = mem_current_data(*extra_field);
                mem_seek(*extra_field, name_length, .CURRENT);

                continue;

            case .EXTENDED_TIMESTAMP;
            case .UNIX_OWNER;
            case .NTFS;

            case;
                log_error("Zip: unrecognized extra field 0x%", formatInt(id, 16, 4));
        }

        // If we're here we didn't handle the extra field. Skip.
        mem_seek(*extra_field, length, .CURRENT);
    }


    return true;
}

read_eocd :: (stream: *Memory_Stream, eocd: *EOCD) -> bool {
    mem_read(stream, *eocd.disk_number);
    mem_read(stream, *eocd.central_dir_start_disk);
    mem_read(stream, *eocd.disk_central_dir_count);
    mem_read(stream, *eocd.central_dir_count);
    mem_read(stream, *eocd.central_dir_byte_count);
    mem_read(stream, *eocd.central_dir_offset);
    mem_read(stream, *eocd.comment_length);

    eocd.comment.count = eocd.comment_length;
    eocd.comment.data = mem_current_data(stream);
    mem_seek(stream, eocd.comment_length, .CURRENT);

    is_zip64 := eocd.central_dir_offset == U32_MAX;

    if is_zip64 {
        // Search backwards for EOCD64 locator
        // Profile this cause it seems slow

        mem_seek(stream, -(EOCD_LENGTH + size_of(EOCD64_Locator) - 4), .CURRENT);

        while true {
            magic: u32;
            mem_read(stream, *magic);
            if magic == ZIP64_LOCATOR_MAGIC break;
            mem_seek(stream, -5, .CURRENT);
        }

        mem_read(stream, *eocd.locator.eocd64_disk);
        mem_read(stream, *eocd.locator.eocd64_offset);
        mem_read(stream, *eocd.locator.disk_count);

        mem_seek(stream, xx eocd.locator.eocd64_offset, .START);

        magic: u32;
        mem_read(stream, *magic);
        if magic != EOCD64_MAGIC return false;

        mem_read(stream, *eocd.eocd64.eocd64_size);
        remaining := eocd.eocd64.eocd64_size;

        remaining -= xx mem_read(stream, *eocd.eocd64.created_version);
        remaining -= xx mem_read(stream, *eocd.eocd64.extract_version);
        remaining -= xx mem_read(stream, *eocd.eocd64.current_disk);
        remaining -= xx mem_read(stream, *eocd.eocd64.central_dir_start_disk);
        remaining -= xx mem_read(stream, *eocd.eocd64.central_dir_count);
        remaining -= xx mem_read(stream, *eocd.eocd64.central_dir_global_count);
        remaining -= xx mem_read(stream, *eocd.eocd64.central_dir_byte_count);
        remaining -= xx mem_read(stream, *eocd.eocd64.central_dir_offset);

        // @TODO: comment
        mem_seek(stream, xx remaining, .CURRENT);
    }

    return true;
}

extract_local_file :: (zip: *Zip, entry: *Local_File, output: *string, allocator: Allocator = .{}) -> bool {
    if entry.general_bitflag & General_Bit.ENCRYPTED {
        log_error("Zip: cannot extract '%', entry is encrypted", entry.file_name);
        return false;
    }

    if entry.compression_method == {
        case .STORE;
            input: string;
            input.data = zip.file.data + entry.data_start;
            input.count = xx entry.compressed_size; // Uncompressed size will be 0

            output.* = copy_string(input,, allocator);

        case .DEFLATE;
            input: string;
            input.count = xx entry.compressed_size;
            input.data = zip.file.data + entry.data_start;

            output.count = xx entry.uncompressed_size;
            output.data = alloc(output.count,, allocator);

            stbi_zlib_decode_noheader_buffer(output.data, xx output.count, input.data, xx input.count);

        case;
            log_error("Zip: cannot extract '%', % not yet supported", entry.file_name, entry.compression_method);
            return false;
    }

    return true;
}

