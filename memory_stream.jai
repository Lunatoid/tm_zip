
#scope_module

#import "Basic";

Memory_Stream :: struct {
    data: [] u8;
    position: s64;
}

mem_open :: (vdata: *void, count: s64) -> Memory_Stream {
    mem: Memory_Stream;
    mem.data.data = vdata;
    mem.data.count = count;

    return mem;
}

mem_open :: (data: [] u8) -> Memory_Stream {
    return .{
        data = data,
        position = 0
    };
}

mem_read :: (mem: *Memory_Stream, vdata: *void, bytes_to_read: s64) -> (success: bool, total_read: s64) {
    data := cast(*u8) vdata;

    if data == null          return false, 0;
    if bytes_to_read <= 0    return false, 0;
    if mem.data.data == null return false, 0;

    remaining := mem.data.count - mem.position;

    total_read := min(bytes_to_read, remaining);
    memcpy(vdata, mem_current_data(mem), total_read);

    mem.position += total_read;

    return total_read == bytes_to_read, total_read;
}

mem_read :: (mem: *Memory_Stream, t: *$T) -> (success: bool, total_read: s64) {
    success, total_read := mem_read(mem, t, size_of(T));
    return success, total_read;
}

mem_read_codepoint :: (mem: *Memory_Stream) -> (code: u32, success: bool) {
    text: string;
    text.data = mem_current_data(mem);
    text.count = mem.data.count - mem.position;

    if text.count <= 0  return 0, false;

    code, success := utf8_next_character(*text);

    return code, success == .CONVERSION_OK;
}

mem_read_line :: (mem: *Memory_Stream) -> (line: string, has_newline: bool) {
    current_position := mem_current_position(mem);

    str: string;
    str.data = mem_current_data(mem);
    str.count = mem.data.count - mem.position;

    has_newline := false;
    newline_size := 1;
    newline_index := find_index_from_left(str, #char "\n");

    if newline_index != -1 {
        has_newline = true;

        // Handle \r\n
        if newline_index > 0 && str[newline_index - 1] == #char "\r" {
            newline_index -= 1;
            newline_size = 2;
        }
    }

    if !has_newline {
        // End-of-stream
        newline_index = str.count;
    }

    str.count = newline_index;
    mem_seek(mem, newline_index + newline_size, .CURRENT);

    return str, has_newline;
}

mem_length :: (mem: *Memory_Stream) -> (length: s64, success: bool) {
    if mem.data.data == null  return 0, false;

    return mem.data.count, true;
}

mem_current_position :: (mem: *Memory_Stream) -> s64, bool {
    return mem.position, mem.data.data != null;
}

mem_set_position :: (mem: *Memory_Stream, pos: s64) -> bool {
    mem.position = clamp(pos, 0, mem_length(mem));
    return mem.data.data != null;
}

mem_seek :: (mem: *Memory_Stream, pos: s64, type: Seek_Type) -> (success: bool) {
    translated_pos: s64;

    if type == {
        case .START;
            translated_pos = pos;
        case .CURRENT;
            translated_pos = mem.position + pos;
        case .END;
            translated_pos = mem_length(mem) + pos;
    }

    mem.position = clamp(translated_pos, 0, mem_length(mem));

    return mem.data.data != null;
}

mem_can_read :: (mem: *Memory_Stream) -> bool {
    return mem.position < mem.data.count;
}

mem_current_data :: (mem: *Memory_Stream) -> *u8 {
    return mem.data.data + mem.position;
}

#scope_module

#import "Unicode";

Seek_Type :: enum {
    START   :: 0;
    CURRENT :: 1;
    END     :: 2;
}
