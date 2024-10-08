const std = @import("std");
const mem = std.mem;
const io = std.io;
const testing = std.testing;

pub const QoS = enum(u2) {
    qos0 = 0,
    qos1,
    qos2,
};

pub const PacketType = enum(u4) {
    connect = 1,
    connack,
    publish,
    puback,
    pubrec,
    pubrel,
    pubcomp,
    subscribe,
    suback,
    unsubscribe,
    unsuback,
    pingreq,
    pingresp,
    disconnect,
};

pub const ParseError = error{ InvalidQoS, UnhandledPacket, InvalidTopicLength };

pub const Packet = union(PacketType) {
    connect: Connect,
    connack: ConnAck,
    publish: Publish,
    puback: PubAck,
    pubrec: PubRec,
    pubrel: PubRel,
    pubcomp: PubComp,
    subscribe: Subscribe,
    suback: SubAck,
    unsubscribe: Unsubscribe,
    unsuback: UnsubAck,
    // Empty packets, no need for backing struct
    pingreq,
    pingresp,
    disconnect,

    const Self = @This();

    const empty_packet_remaining_length = 0;
    const packet_id_only_packet_remaining_length = 2;

    pub fn parse(packet_type: PacketType, buffer: []const u8, flags: u4) !Packet {
        var fis = std.io.fixedBufferStream(buffer);
        const reader = fis.reader();

        switch (packet_type) {
            .connack => {
                const ack_flags = try reader.readByte();
                const session_present = if ((ack_flags & 1) != 0) true else false;
                const return_code = @as(ConnAck.ReturnCode, @enumFromInt(try reader.readByte()));
                const connack = .{ .session_present = session_present, .return_code = return_code };
                return Packet{ .connack = connack };
            },
            .publish => {
                const retain = (flags & 0b0001) == 1;
                const qos_int: u2 = @intCast(@shrExact(flags & 0b0110, 1));
                if (qos_int > 2) {
                    return error.InvalidQoS;
                }
                const qos = @as(QoS, @enumFromInt(qos_int));
                const duplicate = @shrExact(flags & 0b1000, 3) == 1;

                const topic_length = try reader.readInt(u16, .big);
                const topic_start = try fis.getPos();
                const topic_end = topic_start + topic_length;
                if (topic_end >= buffer.len) {
                    return error.InvalidTopicLength;
                }
                const topic = buffer[topic_start..topic_end];
                try fis.seekBy(topic_length);

                const packet_id = switch (qos) {
                    QoS.qos0 => null,
                    QoS.qos1, QoS.qos2 => try reader.readInt(u16, .big),
                };

                const payload_start = try fis.getPos();
                const payload = buffer[payload_start..];

                const publish = .{
                    .retain = retain,
                    .qos = qos,
                    .duplicate = duplicate,
                    .topic = topic,
                    .packet_id = packet_id,
                    .payload = payload,
                };
                return Packet{ .publish = publish };
            },
            .puback => {
                const packet_id = try reader.readInt(u16, .big);
                const puback = .{ .packet_id = packet_id };
                return Packet{ .puback = puback };
            },
            .pubrec => {
                const packet_id = try reader.readInt(u16, .big);
                const pubrec = .{ .packet_id = packet_id };
                return Packet{ .pubrec = pubrec };
            },
            .pubrel => {
                const packet_id = try reader.readInt(u16, .big);
                const pubrel = .{ .packet_id = packet_id };
                return Packet{ .pubrel = pubrel };
            },
            .pubcomp => {
                const packet_id = try reader.readInt(u16, .big);
                const pubcomp = .{ .packet_id = packet_id };
                return Packet{ .pubcomp = pubcomp };
            },
            .suback => {
                const packet_id = try reader.readInt(u16, .big);
                const return_codes_start = try fis.getPos();
                const return_codes = mem.bytesAsSlice(SubAck.ReturnCode, buffer[return_codes_start..]);

                const suback = .{
                    .packet_id = packet_id,
                    .return_codes = return_codes,
                };
                return Packet{ .suback = suback };
            },
            .unsuback => {
                const packet_id = try reader.readInt(u16, .big);
                const unsuback = .{ .packet_id = packet_id };
                return Packet{ .unsuback = unsuback };
            },
            .pingresp => return .pingresp,
            // We only handle server -> client packets
            else => return error.UnhandledPacket,
        }
    }

    pub fn serializedLength(self: Self) !usize {
        const remaining_length =
            switch (self) {
            .connect => |connect| connect.remainingLength(),
            .publish => |publish| publish.remainingLength(),
            .puback, .pubrec, .pubrel, .pubcomp => packet_id_only_packet_remaining_length,
            .subscribe => |subscribe| subscribe.remainingLength(),
            .unsubscribe => |unsubscribe| unsubscribe.remainingLength(),
            .pingreq, .disconnect => empty_packet_remaining_length,
            // We only handle client -> server packets
            else => return error.UnhandledPacket,
        };
        const fixed_header_length = try serializedFixedHeaderLength(remaining_length);

        return fixed_header_length + remaining_length;
    }

    pub fn serialize(self: Self, buffer: []u8) !void {
        return switch (self) {
            .connect => |connect| connect.serialize(buffer),
            .publish => |publish| publish.serialize(buffer),
            .puback => |puback| serializePacketIdOnlyPacket(.puback, puback.packet_id, buffer),
            .pubrec => |pubrec| serializePacketIdOnlyPacket(.pubrec, pubrec.packet_id, buffer),
            .pubrel => |pubrel| serializePacketIdOnlyPacket(.pubrel, pubrel.packet_id, buffer),
            .pubcomp => |pubcomp| serializePacketIdOnlyPacket(.pubcomp, pubcomp.packet_id, buffer),
            .subscribe => |subscribe| subscribe.serialize(buffer),
            .unsubscribe => |unsubscribe| unsubscribe.serialize(buffer),
            .pingreq => serializeEmptyPacket(.pingreq, buffer),
            .disconnect => serializeEmptyPacket(.disconnect, buffer),
            // We only handle client -> server packets
            else => return error.UnhandledPacket,
        };
    }

    fn serializePacketIdOnlyPacket(packet_type: PacketType, packet_id: u16, buffer: []u8) !void {
        var fis = std.io.fixedBufferStream(buffer);
        const writer = fis.writer();

        const remaining_length = packet_id_only_packet_remaining_length;
        const header_flags: u4 = 0;
        try writeFixedHeader(writer, packet_type, header_flags, remaining_length);
        try writer.writeInt(u16, packet_id, .big);
    }

    fn serializeEmptyPacket(packet_type: PacketType, buffer: []u8) !void {
        var fis = std.io.fixedBufferStream(buffer);
        const writer = fis.writer();

        const remaining_length = empty_packet_remaining_length;
        const header_flags: u4 = 0;
        try writeFixedHeader(writer, packet_type, header_flags, remaining_length);
    }
};

// Constant that are used across packages to calculate serialized length
const packet_id_length = @sizeOf(u16);

pub const Connect = struct {
    clean_session: bool,
    keepalive: u16,
    client_id: []const u8,
    will: ?Will = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    const Self = @This();

    pub const Will = struct {
        topic: []const u8,
        message: []const u8,
        retain: bool,
        qos: QoS,
    };

    const Flags = packed struct {
        _reserved: u1 = 0,
        clean_session: bool,
        will_flag: bool,
        will_qos: u2,
        will_retain: bool,
        password_flag: bool,
        username_flag: bool,
    };

    const protocol_name = "MQTT";
    const protocol_name_length = @sizeOf(u16) + protocol_name.len;
    const protocol_level: u8 = 4;
    const protocol_level_length = @sizeOf(@TypeOf(protocol_level));
    const flags_length = @sizeOf(Flags);
    const keepalive_length = @sizeOf(u16);

    pub fn remainingLength(self: Self) u32 {
        // Fixed initial fields
        var length: u32 = protocol_name_length + protocol_level_length + flags_length + keepalive_length;

        length += serializedMqttStringLength(self.client_id);

        if (self.will) |will| {
            length += serializedMqttStringLength(will.message);
            length += serializedMqttStringLength(will.topic);
            // Will retain and qos go in flags, no space needed
        }

        if (self.username) |username| {
            length += serializedMqttStringLength(username);
        }

        if (self.password) |password| {
            length += serializedMqttStringLength(password);
        }

        return length;
    }

    pub fn serialize(self: Self, buffer: []u8) !void {
        var fis = std.io.fixedBufferStream(buffer);
        const writer = fis.writer();

        const remaining_length = self.remainingLength();
        const header_flags: u4 = 0;
        try writeFixedHeader(writer, .connect, header_flags, remaining_length);

        try writeMqttString(writer, protocol_name);
        try writer.writeByte(protocol_level);

        // Extract info from Will, if there's one
        var will_message: ?[]const u8 = null;
        var will_topic: ?[]const u8 = null;
        var will_qos = QoS.qos0;
        var will_retain = false;
        if (self.will) |will| {
            will_topic = will.topic;
            will_message = will.message;
            will_qos = will.qos;
            will_retain = will.retain;
        }

        const flags = Flags{
            .clean_session = self.clean_session,
            .will_flag = self.will != null,
            .will_qos = @intFromEnum(will_qos),
            .will_retain = will_retain,
            .password_flag = self.password != null,
            .username_flag = self.username != null,
        };
        const flags_byte = @as(u8, @bitCast(flags));
        try writer.writeByte(flags_byte);

        try writer.writeInt(u16, self.keepalive, .big);

        try writeMqttString(writer, self.client_id);

        if (will_topic) |wt| {
            try writeMqttString(writer, wt);
        }

        if (will_message) |wm| {
            try writeMqttString(writer, wm);
        }

        if (self.username) |username| {
            try writeMqttString(writer, username);
        }

        if (self.password) |password| {
            try writeMqttString(writer, password);
        }
    }
};

pub const ConnAck = struct {
    session_present: bool,
    return_code: ReturnCode,

    pub const ReturnCode = enum(u8) {
        ok = 0,
        unacceptable_protocol_version,
        invalid_client_id,
        server_unavailable,
        malformed_credentials,
        unauthorized,
    };
};

pub const Publish = struct {
    duplicate: bool = false,
    qos: QoS,
    retain: bool,
    topic: []const u8,
    packet_id: ?u16 = null,
    payload: []const u8,

    const Self = @This();

    pub fn remainingLength(self: Self) u32 {
        const length: u32 = serializedMqttStringLength(self.topic) + @as(u32, @intCast(self.payload.len));

        switch (self.qos) {
            QoS.qos0 => return length, // No packet id
            QoS.qos1, QoS.qos2 => return length + @sizeOf(u16), // Add space for packet id
        }
    }

    pub fn serialize(self: Self, buffer: []u8) !void {
        var fis = std.io.fixedBufferStream(buffer);
        const writer = fis.writer();

        const remaining_length = self.remainingLength();
        const header_flags: u4 =
            @as(u4, @intFromBool(self.retain)) |
            @shlExact(@as(u4, @intFromEnum(self.qos)), 1) |
            @shlExact(@as(u4, @intFromBool(self.duplicate)), 3);

        try writeFixedHeader(writer, .publish, header_flags, remaining_length);
        try writeMqttString(writer, self.topic);
        switch (self.qos) {
            QoS.qos0 => {}, // No packet id
            QoS.qos1, QoS.qos2 => {
                if (self.packet_id) |packet_id| {
                    try writer.writeInt(u16, packet_id, .big);
                } else {
                    return error.MissingPacketId;
                }
            },
        }
        try writer.writeAll(self.payload);
    }
};

pub const PubAck = struct {
    packet_id: u16,
};

pub const PubRec = struct {
    packet_id: u16,
};

pub const PubRel = struct {
    packet_id: u16,
};

pub const PubComp = struct {
    packet_id: u16,
};

pub const Subscribe = struct {
    packet_id: u16,
    topics: []const Topic,

    const Self = @This();

    pub const Topic = struct {
        topic_filter: []const u8,
        qos: QoS,
    };

    pub fn remainingLength(self: Self) u32 {
        // Fixed initial fields
        var length: u32 = packet_id_length;

        for (self.topics) |topic| {
            length += serializedMqttStringLength(topic.topic_filter);
            length += @sizeOf(@TypeOf(topic.qos));
        }

        return length;
    }

    pub fn serialize(self: Self, buffer: []u8) !void {
        var fis = std.io.fixedBufferStream(buffer);
        const writer = fis.writer();

        const remaining_length = self.remainingLength();
        const header_flags: u4 = 0b0010; // MQTT v3.1.1 spec section 3.8.1
        try writeFixedHeader(writer, .subscribe, header_flags, remaining_length);
        try writer.writeInt(u16, self.packet_id, .big);
        for (self.topics) |topic| {
            try writeMqttString(writer, topic.topic_filter);
            try writer.writeInt(u8, @intFromEnum(topic.qos), .big);
        }
    }
};

pub const SubAck = struct {
    packet_id: u16,
    return_codes: []const ReturnCode,

    pub const ReturnCode = enum(u8) {
        success_qos0 = 0,
        success_qos1,
        success_qos2,
        failure = 0x80,
    };
};

pub const Unsubscribe = struct {
    packet_id: u16,
    topic_filters: []const []const u8,

    const Self = @This();

    pub fn remainingLength(self: Self) u32 {
        // Fixed initial fields
        var length: u32 = packet_id_length;

        for (self.topic_filters) |topic_filter| {
            length += serializedMqttStringLength(topic_filter);
        }

        return length;
    }

    pub fn serialize(self: Self, buffer: []u8) !void {
        var fis = std.io.fixedBufferStream(buffer);
        const writer = fis.writer();

        const remaining_length = self.remainingLength();
        const header_flags: u4 = 0b0010; // MQTT v3.1.1 spec section 3.10.1
        try writeFixedHeader(writer, .unsubscribe, header_flags, remaining_length);
        try writer.writeInt(u16, self.packet_id, .big);
        for (self.topic_filters) |topic_filter| {
            try writeMqttString(writer, topic_filter);
        }
    }
};

pub const UnsubAck = struct {
    packet_id: u16,
};

fn serializedMqttStringLength(s: []const u8) u16 {
    return @as(u16, @intCast(s.len)) + 2;
}

fn serializedFixedHeaderLength(remaining_length: usize) !usize {
    const type_and_flags_length = @sizeOf(u8);
    const remaining_length_bytes: usize = switch (remaining_length) {
        0...127 => 1,
        128...16_383 => 2,
        16_384...2_097_151 => 3,
        2_097_152...268_435_455 => 4,
        else => return error.PacketTooBig,
    };

    return type_and_flags_length + remaining_length_bytes;
}

fn writeMqttString(writer: anytype, s: []const u8) !void {
    const length = @as(u16, @intCast(s.len));
    try writer.writeInt(u16, length, .big);
    try writer.writeAll(s);
}

fn writeFixedHeader(writer: anytype, packet_type: PacketType, flags: u4, remaining_length: u32) !void {
    const type_and_flags: u8 = @shlExact(@as(u8, @intFromEnum(packet_type)), 4) | flags;
    try writer.writeByte(type_and_flags);
    var value: u32 = remaining_length;
    const max_bytes = @sizeOf(u32);
    var i: u8 = 0;
    while (i < max_bytes) : (i += 1) {
        var byte: u8 = @intCast(value % 128);
        value /= 128;
        if (value > 0) {
            byte |= 128;
        }
        try writer.writeByte(byte);

        if (value == 0) return;
    }

    return error.InvalidLength;
}

test {
    testing.refAllDecls(@This());
}
