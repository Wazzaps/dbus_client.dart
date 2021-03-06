import 'package:unix_domain_socket/unix_domain_socket.dart';

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

// FIXME: Handle endianess - currently hard-coded to little
// FIXME: Use more efficient data store than List<int>?
// FIXME: Use ByteData more efficiently - don't copy when reading/writing

class Endianess {
  static const Little = 108; // ASCII 'l'
  static const Big = 66; // ASCII 'B'
}

class MessageType {
  static const Invalid = 0;
  static const MethodCall = 1;
  static const MethodReturn = 2;
  static const Error = 3;
  static const Signal = 4;
}

class Flags {
  static const NoReplyExpected = 0x01;
  static const NoAutoStart = 0x02;
  static const AllowInteractiveAuthorization = 0x04;
}

class HeaderCode {
  static const Invalid = 0;
  static const Path = 1;
  static const Interface = 2;
  static const Member = 3;
  static const ErrorName = 4;
  static const ReplySerial = 5;
  static const Destination = 6;
  static const Sender = 7;
  static const Signature = 8;
  static const UnixFds = 9;
}

const ProtocolVersion = 1;

class DBusWriteBuffer {
  var data = List<int>();

  writeByte(int value) {
    data.add(value);
  }

  writeBytes(Iterable<int> value) {
    data.addAll(value);
  }

  writeInt16(int value) {
    var bytes = Uint8List(2).buffer;
    ByteData.view(bytes).setInt16(0, value, Endian.little);
    writeBytes(bytes.asUint8List());
  }

  writeUint16(int value) {
    var bytes = Uint8List(2).buffer;
    ByteData.view(bytes).setUint16(0, value, Endian.little);
    writeBytes(bytes.asUint8List());
  }

  writeInt32(int value) {
    var bytes = Uint8List(4).buffer;
    ByteData.view(bytes).setInt32(0, value, Endian.little);
    writeBytes(bytes.asUint8List());
  }

  writeUint32(int value) {
    var bytes = Uint8List(4).buffer;
    ByteData.view(bytes).setUint32(0, value, Endian.little);
    writeBytes(bytes.asUint8List());
  }

  writeInt64(int value) {
    var bytes = Uint8List(8).buffer;
    ByteData.view(bytes).setInt64(0, value, Endian.little);
    writeBytes(bytes.asUint8List());
  }

  writeUint64(int value) {
    var bytes = Uint8List(8).buffer;
    ByteData.view(bytes).setUint64(0, value, Endian.little);
    writeBytes(bytes.asUint8List());
  }

  writeFloat64(double value) {
    var bytes = Uint8List(8).buffer;
    ByteData.view(bytes).setFloat64(0, value, Endian.little);
    writeBytes(bytes.asUint8List());
  }

  setByte(int offset, int value) {
    data[offset] = value;
  }

  align(int boundary) {
    while (data.length % boundary != 0) writeByte(0);
  }
}

class DBusReadBuffer {
  var data = List<int>();
  int readOffset = 0;

  int get remaining {
    return data.length - readOffset;
  }

  writeBytes(Iterable<int> value) {
    data.addAll(value);
  }

  int readByte() {
    readOffset++;
    return data[readOffset - 1];
  }

  ByteBuffer readBytes(int length) {
    var bytes = Uint8List(length);
    for (var i = 0; i < length; i++) bytes[i] = readByte();
    return bytes.buffer;
  }

  int readInt16() {
    return ByteData.view(readBytes(2)).getInt16(0, Endian.little);
  }

  int readUint16() {
    return ByteData.view(readBytes(2)).getUint16(0, Endian.little);
  }

  int readInt32() {
    return ByteData.view(readBytes(4)).getInt32(0, Endian.little);
  }

  int readUint32() {
    return ByteData.view(readBytes(4)).getUint32(0, Endian.little);
  }

  int readInt64() {
    return ByteData.view(readBytes(8)).getInt64(0, Endian.little);
  }

  int readUint64() {
    return ByteData.view(readBytes(8)).getUint64(0, Endian.little);
  }

  double readFloat64() {
    return ByteData.view(readBytes(8)).getFloat64(0, Endian.little);
  }

  bool align(int boundary) {
    while (readOffset % boundary != 0) {
      if (remaining == 0) return false;
      readOffset++;
    }
    return true;
  }

  flush() {
    data.removeRange(0, readOffset);
    readOffset = 0;
  }

  @override
  toString() {
    var s = '';
    for (var d in data) {
      if (d >= 33 && d <= 126)
        s += String.fromCharCode(d);
      else
        s += '\\' + d.toRadixString(8);
    }
    return "DBusReadBuffer('${s}')";
  }
}

class DBusValue {
  static DBusValue fromSignature(DBusSignature signature) {
    var s = signature.value;
    if (s == 'y')
      return DBusByte(0);
    else if (s == 'b')
      return DBusBoolean(false);
    else if (s == 'n')
      return DBusInt16(0);
    else if (s == 'q')
      return DBusUint16(0);
    else if (s == 'i')
      return DBusInt32(0);
    else if (s == 'u')
      return DBusUint32(0);
    else if (s == 'x')
      return DBusInt64(0);
    else if (s == 't')
      return DBusUint64(0);
    else if (s == 'd')
      return DBusDouble(0);
    else if (s == 's')
      return DBusString('');
    else if (s == 'o')
      return DBusObjectPath('');
    else if (s == 'g')
      return DBusSignature('');
    else if (s == 'v')
      return DBusVariant(null);
    else if (s.startsWith('a{') && s.endsWith('}')) {
      var childSignature = DBusSignature(s.substring(2, s.length));
      var signatures = childSignature.split(); // FIXME: Check two signatures
      return DBusDict(signatures[0], signatures[1]);
    } else if (s.startsWith('a'))
      return DBusArray(
          DBusValue.fromSignature(DBusSignature(s.substring(1, s.length + 1))));
    else if (s.startsWith('(') && s.endsWith(')')) {
      var children = List<DBusValue>();
      for (var i = 1; i < s.length - 1; i++)
        children.add(DBusValue.fromSignature(DBusSignature(s[i])));
      return DBusStruct(children);
    } else
      throw "Unknown DBus data type '${s}'";
  }

  DBusSignature signature;
  int alignment;

  marshal(DBusWriteBuffer buffer) {}

  bool unmarshal(DBusReadBuffer buffer) {
    return false;
  }
}

class DBusByte extends DBusValue {
  int value;
  static final _signature = DBusSignature('y');

  DBusByte(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 1;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.writeByte(this.value);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (buffer.remaining < 1) return false;
    value = buffer.readByte();
    return true;
  }

  @override
  String toString() {
    return 'DBusByte(${value})';
  }
}

class DBusBoolean extends DBusValue {
  bool value;
  static final _signature = DBusSignature('b');

  DBusBoolean(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 4;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.align(this.alignment);
    buffer.writeUint32(value ? 1 : 0);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (!buffer.align(this.alignment)) return false;
    if (buffer.remaining < 4) return false;
    value = buffer.readUint32() != 0;
    return true;
  }

  @override
  String toString() {
    return 'DBusBoolean(${value})';
  }
}

class DBusInt16 extends DBusValue {
  int value;
  static final _signature = DBusSignature('n');

  DBusInt16(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 2;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.align(this.alignment);
    buffer.writeInt16(value);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (!buffer.align(this.alignment)) return false;
    if (buffer.remaining < 2) return false;
    value = buffer.readInt16();
    return true;
  }

  @override
  String toString() {
    return 'DBusInt16(${value})';
  }
}

class DBusUint16 extends DBusValue {
  int value;
  static final _signature = DBusSignature('q');

  DBusUint16(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 2;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.align(this.alignment);
    buffer.writeUint16(value);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (!buffer.align(this.alignment)) return false;
    if (buffer.remaining < 2) return false;
    value = buffer.readUint16();
    return true;
  }

  @override
  String toString() {
    return 'DBusUint16(${value})';
  }
}

class DBusInt32 extends DBusValue {
  int value;
  static final _signature = DBusSignature('i');

  DBusInt32(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 4;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.align(this.alignment);
    buffer.writeInt32(value);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (!buffer.align(this.alignment)) return false;
    if (buffer.remaining < 4) return false;
    value = buffer.readInt32();
    return true;
  }

  @override
  String toString() {
    return 'DBusInt32(${value})';
  }
}

class DBusUint32 extends DBusValue {
  int value;
  static final _signature = DBusSignature('u');

  DBusUint32(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 4;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.align(this.alignment);
    buffer.writeUint32(value);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (!buffer.align(this.alignment)) return false;
    if (buffer.remaining < 4) return false;
    value = buffer.readUint32();
    return true;
  }

  @override
  String toString() {
    return 'DBusUint32(${value})';
  }
}

class DBusInt64 extends DBusValue {
  int value;
  static final _signature = DBusSignature('x');

  DBusInt64(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 8;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.align(this.alignment);
    buffer.writeInt64(value);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (!buffer.align(this.alignment)) return false;
    if (buffer.remaining < 8) return false;
    value = buffer.readInt64();
    return true;
  }

  @override
  String toString() {
    return 'DBusInt64(${value})';
  }
}

class DBusUint64 extends DBusValue {
  int value;
  static final _signature = DBusSignature('t');

  DBusUint64(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 8;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.align(this.alignment);
    buffer.writeUint64(value);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (!buffer.align(this.alignment)) return false;
    if (buffer.remaining < 8) return false;
    value = buffer.readUint64();
    return true;
  }

  @override
  String toString() {
    return 'DBusUint64(${value})';
  }
}

class DBusDouble extends DBusValue {
  double value;
  static final _signature = DBusSignature('d');

  DBusDouble(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 8;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.align(this.alignment);
    buffer.writeFloat64(value);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (!buffer.align(this.alignment)) return false;
    if (buffer.remaining < 8) return false;
    value = buffer.readFloat64();
    return true;
  }

  @override
  String toString() {
    return 'DBusDouble(${value})';
  }
}

class DBusString extends DBusValue {
  String value;
  static final _signature = DBusSignature('s');

  DBusString(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 4;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    var data = utf8.encode(value);
    var length = DBusUint32(value.length);
    length.marshal(buffer);
    for (var d in data) buffer.writeByte(d);
    buffer.writeByte(0);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    var length = DBusUint32(0);
    if (!length.unmarshal(buffer)) return false;
    if (buffer.remaining < (length.value + 1)) return false;
    var values = List<int>();
    for (var i = 0; i < length.value; i++) values.add(buffer.readByte());
    this.value = utf8.decode(values);
    buffer.readByte(); // Trailing nul
    return true;
  }

  @override
  String toString() {
    return "DBusString('${value}')";
  }
}

class DBusObjectPath extends DBusString {
  static final _signature = DBusSignature('o');

  DBusObjectPath(String value) : super(value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  String toString() {
    return "DBusObjectPath('${value}')";
  }
}

class DBusSignature extends DBusValue {
  String value;
  static final _signature = DBusSignature('g');

  DBusSignature(this.value);

  List<DBusSignature> split() {
    var signatures = List<DBusSignature>();
    for (var i = 0; i < value.length; i++) {
      if (value[i] == 'a') {
        if (value[i + 1] == '(') {
          var count = 1;
          var end = i + 2;
          while (count > 0) {
            if (value[end] == '(') count++;
            if (value[end] == ')') count--;
            end++;
          }
          signatures.add(DBusSignature(value.substring(i, end)));
          i += end - i;
        } else if (value[i + 1] == '{') {
          var count = 1;
          var end = i + 2;
          while (count > 0) {
            if (value[end] == '{') count++;
            if (value[end] == '}') count--;
            end++;
          }
          signatures.add(DBusSignature(value.substring(i, end)));
          i += end - i;
        } else {
          signatures.add(DBusSignature(value.substring(i, i + 2)));
          i++;
        }
      } else
        signatures.add(DBusSignature(value[i]));
    }
    return signatures;
  }

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 1;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    var data = utf8.encode(value);
    buffer.writeByte(value.length);
    for (var d in data) buffer.writeByte(d);
    buffer.writeByte(0);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (buffer.remaining < 1) return false;
    var length = buffer.readByte();
    var values = List<int>();
    if (buffer.remaining < length + 1) return false;
    for (var i = 0; i < length; i++) values.add(buffer.readByte());
    value = utf8.decode(values);
    buffer.readByte(); // Trailing nul
    return true;
  }

  @override
  String toString() {
    return "DBusSignature('${value}')";
  }
}

class DBusVariant extends DBusValue {
  DBusValue value;
  static final _signature = DBusSignature('v');

  DBusVariant(this.value);

  @override
  DBusSignature get signature {
    return _signature;
  }

  @override
  int get alignment {
    return 1;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    value.signature.marshal(buffer);
    value.marshal(buffer);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    var signature = DBusSignature('');
    if (!signature.unmarshal(buffer)) return false;
    value = DBusValue.fromSignature(signature);
    return value.unmarshal(buffer);
  }

  @override
  String toString() {
    return 'DBusVariant(${value.toString()})';
  }
}

class DBusStruct extends DBusValue {
  List<DBusValue> children;

  DBusStruct(this.children);

  @override
  int get alignment {
    return 8;
  }

  @override
  DBusSignature get signature {
    var signature = '';
    for (var child in children) signature += child.signature.value;
    return DBusSignature('(' + signature + ')');
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    buffer.align(this.alignment);
    for (var child in children) child.marshal(buffer);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    if (!buffer.align(this.alignment)) return false;
    for (var child in children) {
      if (!child.unmarshal(buffer)) return false;
    }

    return true;
  }

  @override
  String toString() {
    var childrenText = List<String>();
    for (var child in children) childrenText.add(child.toString());
    return "DBusStruct([${childrenText.join(', ')}])";
  }
}

class DBusArray extends DBusValue {
  final DBusSignature childSignature;
  var children = List<DBusValue>();

  DBusArray(this.childSignature);

  add(DBusValue value) {
    children.add(value);
  }

  @override
  DBusSignature get signature {
    return DBusSignature('a' + childSignature.value);
  }

  @override
  int get alignment {
    return 4;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    DBusUint32(0).marshal(buffer);
    var lengthOffset = buffer.data.length - 4;
    if (children.length > 0) buffer.align(children[0].alignment);
    var startOffset = buffer.data.length;
    for (var child in children) child.marshal(buffer);

    // Update the length that was written
    var length = buffer.data.length - startOffset;
    buffer.setByte(lengthOffset + 0, (length >> 0) & 0xFF);
    buffer.setByte(lengthOffset + 1, (length >> 8) & 0xFF);
    buffer.setByte(lengthOffset + 2, (length >> 16) & 0xFF);
    buffer.setByte(lengthOffset + 3, (length >> 24) & 0xFF);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    var length = DBusUint32(0);
    if (!length.unmarshal(buffer)) return false;
    // FIXME: Align to first element (not in length)
    var end = buffer.readOffset + length.value;
    while (buffer.readOffset < end) {
      var child = DBusValue.fromSignature(childSignature);
      if (!child.unmarshal(buffer)) return false;
      children.add(child);
    }

    return true;
  }

  @override
  String toString() {
    var childrenText = List<String>();
    for (var child in children) childrenText.add(child.toString());
    return "DBusArray([${childrenText.join(', ')}])";
  }
}

class DBusDict extends DBusValue {
  final DBusSignature keySignature;
  final DBusSignature valueSignature;
  var children = List<DBusStruct>();

  DBusDict(this.keySignature, this.valueSignature);

  add(DBusValue key, DBusValue value) {
    // FIXME: Check if key exists
    children.add(DBusStruct([key, value]));
  }

  DBusValue lookup(DBusValue key) {
    for (var child in children) if (child.children[0] == key) return child;
    return null;
  }

  @override
  DBusSignature get signature {
    return DBusSignature('a{${keySignature.value}${valueSignature.value}}');
  }

  @override
  int get alignment {
    return 4;
  }

  @override
  marshal(DBusWriteBuffer buffer) {
    DBusUint32(0).marshal(buffer);
    var lengthOffset = buffer.data.length - 4;
    if (children.length > 0) buffer.align(children[0].alignment);
    var startOffset = buffer.data.length;
    for (var child in children) child.marshal(buffer);

    // Update the length that was written
    var length = buffer.data.length - startOffset;
    buffer.setByte(lengthOffset + 0, (length >> 0) & 0xFF);
    buffer.setByte(lengthOffset + 1, (length >> 8) & 0xFF);
    buffer.setByte(lengthOffset + 2, (length >> 16) & 0xFF);
    buffer.setByte(lengthOffset + 3, (length >> 24) & 0xFF);
  }

  @override
  bool unmarshal(DBusReadBuffer buffer) {
    var length = DBusUint32(0);
    if (!length.unmarshal(buffer)) return false;
    // FIXME: Align to first element (not in length)
    var end = buffer.readOffset + length.value;
    while (buffer.readOffset < end) {
      var child = DBusStruct([
        DBusValue.fromSignature(keySignature),
        DBusValue.fromSignature(valueSignature)
      ]);
      if (!child.unmarshal(buffer)) return false;
      children.add(child);
    }

    return true;
  }

  @override
  String toString() {
    var childrenText = List<String>();
    for (var child in children) childrenText.add(child.toString());
    return "DBusDict([${childrenText.join(', ')}])";
  }
}

class DBusMessage {
  int type;
  int flags;
  int serial;
  String path;
  String interface;
  String member;
  String errorName;
  int replySerial;
  String destination;
  String sender;
  var values = List<DBusValue>();

  DBusMessage(
      {this.type = MessageType.Invalid,
      this.flags = 0,
      this.serial = 0,
      this.path,
      this.interface,
      this.member,
      this.errorName,
      this.replySerial,
      this.destination,
      this.sender,
      this.values});

  marshal(DBusWriteBuffer buffer) {
    var valueBuffer = DBusWriteBuffer();
    for (var value in values) value.marshal(valueBuffer);

    DBusByte(Endianess.Little).marshal(buffer);
    DBusByte(type).marshal(buffer);
    DBusByte(flags).marshal(buffer);
    DBusByte(ProtocolVersion).marshal(buffer);
    DBusUint32(valueBuffer.data.length).marshal(buffer);
    DBusUint32(serial).marshal(buffer);
    var headerArray = DBusArray(DBusSignature('(yv)'));
    if (this.path != null)
      headerArray.add(_makeHeader(HeaderCode.Path, DBusObjectPath(this.path)));
    if (this.interface != null)
      headerArray
          .add(_makeHeader(HeaderCode.Interface, DBusString(this.interface)));
    if (this.member != null)
      headerArray.add(_makeHeader(HeaderCode.Member, DBusString(this.member)));
    if (this.errorName != null)
      headerArray
          .add(_makeHeader(HeaderCode.ErrorName, DBusString(this.errorName)));
    if (this.replySerial != null)
      headerArray.add(
          _makeHeader(HeaderCode.ReplySerial, DBusUint32(this.replySerial)));
    if (this.destination != null)
      headerArray.add(
          _makeHeader(HeaderCode.Destination, DBusString(this.destination)));
    if (this.sender != null)
      headerArray.add(_makeHeader(HeaderCode.Sender, DBusString(this.sender)));
    if (this.values.length > 0) {
      String signature = '';
      for (var value in values) signature += value.signature.value;
      headerArray
          .add(_makeHeader(HeaderCode.Signature, DBusSignature(signature)));
    }
    headerArray.marshal(buffer);
    buffer.align(8);
    buffer.writeBytes(valueBuffer.data);
  }

  DBusStruct _makeHeader(int code, DBusValue value) {
    return DBusStruct([DBusByte(code), DBusVariant(value)]);
  }

  bool unmarshal(DBusReadBuffer buffer) {
    if (buffer.remaining < 12) return false;

    var endianess = DBusByte(0);
    endianess.unmarshal(buffer);
    var type = DBusByte(0);
    type.unmarshal(buffer);
    this.type = type.value;
    var flags = DBusByte(0);
    flags.unmarshal(buffer);
    this.flags = flags.value;
    var protocolVersion = DBusByte(0);
    protocolVersion.unmarshal(buffer);
    var dataLength = DBusUint32(0);
    dataLength.unmarshal(buffer);
    var serial = DBusUint32(0);
    serial.unmarshal(buffer);
    this.serial = serial.value;
    var headers = DBusArray(DBusSignature('(yv)'));
    if (!headers.unmarshal(buffer)) return false;

    DBusSignature signature;
    for (var child in headers.children) {
      var header = child as DBusStruct;
      var code = (header.children[0] as DBusByte).value;
      var value = (header.children[1] as DBusVariant).value;
      if (code == HeaderCode.Path)
        this.path = (value as DBusObjectPath).value;
      else if (code == HeaderCode.Interface)
        this.interface = (value as DBusString).value;
      else if (code == HeaderCode.Member)
        this.member = (value as DBusString).value;
      else if (code == HeaderCode.ErrorName)
        this.errorName = (value as DBusString).value;
      else if (code == HeaderCode.ReplySerial)
        this.replySerial = (value as DBusUint32).value;
      else if (code == HeaderCode.Destination)
        this.destination = (value as DBusString).value;
      else if (code == HeaderCode.Sender)
        this.sender = (value as DBusString).value;
      else if (code == HeaderCode.Signature) signature = value as DBusSignature;
    }
    if (!buffer.align(8)) return false;

    this.values = List<DBusValue>();
    if (signature != null) {
      var signatures = signature.split();
      for (var s in signatures) {
        var value = DBusValue.fromSignature(s);
        if (!value.unmarshal(buffer)) return false;
        values.add(value);
      }
    }

    return true;
  }

  @override
  String toString() {
    var text = 'DBusMessage(type=';
    if (type == MessageType.MethodCall)
      text += 'MessageType.MethodCall';
    else if (type == MessageType.MethodReturn)
      text += 'MessageType.MethodReturn';
    else if (type == MessageType.Error)
      text += 'MessageType.Error';
    else if (type == MessageType.Signal)
      text += 'MessageType.Signal';
    else
      text += '${type}';
    if (flags != 0) {
      var flagNames = List<String>();
      if (flags & Flags.NoReplyExpected != 0)
        flagNames.add('Flags.NoReplyExpected');
      if (flags & Flags.NoAutoStart != 0) flagNames.add('Flags.NoAutoStart');
      if (flags & Flags.AllowInteractiveAuthorization != 0)
        flagNames.add('Flags.AllowInteractiveAuthorization');
      if (flags & 0xF8 != 0)
        flagNames.add((flags & 0xF8).toRadixString(16).padLeft(2));
      text += ' flags=${flagNames.join('|')}';
    }
    text += ' serial=${serial}';
    if (path != null) text += ", path='${path}'";
    if (interface != null) text += ", interface='${interface}'";
    if (member != null) text += ", member='${member}'";
    if (errorName != null) text += ", errorName='${errorName}'";
    if (replySerial != null) text += ", replySerial=${replySerial}";
    if (destination != null) text += ", destination='${destination}'";
    if (sender != null) text += ", sender='${sender}'";
    if (values.length > 0) {
      var valueText = List<String>();
      for (var value in values) valueText.add(value.toString());
      text += ", values=[${valueText.join(', ')}]";
    }
    text += ')';
    return text;
  }
}

class ReadData {
  UnixDomainSocket socket;
  SendPort port;
}

class DBusClient {
  UnixDomainSocket _socket;
  var _lastSerial = 0;
  Stream _messageStream;

  DBusClient.system() {
    var address = Platform.environment['DBUS_SYSTEM_BUS_ADDRESS'];
    if (address == null) address = 'unix:path=/run/dbus/system_bus_socket';
    _setAddress(address);
  }

  DBusClient.session() {
    var address = Platform.environment['DBUS_SESSION_BUS_ADDRESS'];
    if (address == null) {
      var runtimeDir = Platform.environment['XDG_USER_DIR'];
      if (runtimeDir == null) {
        var uid = Platform.environment[
            'UID']; // FIXME: What to do if can't get this? No UID API in Dart
        runtimeDir = '/run/user/${uid}';
      }
      address = "unix:path=${runtimeDir}/bus";
    }
    _setAddress(address);
  }

  _setAddress(String address) {
    var prefix = 'unix:path=';
    if (!address.startsWith(prefix))
      throw 'D-Bus address not supported: ${address}';
    var path = address.substring(prefix.length);
    _socket = UnixDomainSocket.create(path);
    var dbusMessages = ReceivePort();
    _messageStream = dbusMessages.asBroadcastStream();
    var data = ReadData();
    data.port = dbusMessages.sendPort;
    data.socket = _socket;
    Isolate.spawn(_read, data);

    _authenticate();
  }

  listenSignal(
      void onSignal(String path, String interface, String member,
          List<DBusValue> values)) {
    _messageStream.listen((dynamic receivedData) {
      var message = receivedData as DBusMessage;
      if (message.type == MessageType.Signal)
        onSignal(
            message.path, message.interface, message.member, message.values);
    });
  }

  // FIXME: Should be async
  listenMethod(
      String interface,
      List<DBusValue> onMethod(String path, String interface, String member,
          List<DBusValue> values)) {
    _messageStream.listen((dynamic receivedData) {
      var message = receivedData as DBusMessage;
      if (message.type == MessageType.MethodCall &&
          message.interface == interface) {
        var result = onMethod(
            message.path, message.interface, message.member, message.values);
        _lastSerial++;
        var response = DBusMessage(
            type: MessageType.MethodReturn,
            serial: _lastSerial,
            replySerial: message.serial,
            destination: message.sender,
            values: result);
        _sendMessage(response);
      }
    });
  }

  connect() async {
    await callMethod(
        destination: 'org.freedesktop.DBus',
        path: '/org/freedesktop/DBus',
        interface: 'org.freedesktop.DBus',
        member: 'Hello');
  }

  Future<int> requestName(String name, {int flags = 0}) async {
    var result = await callMethod(
        destination: 'org.freedesktop.DBus',
        path: '/org/freedesktop/DBus',
        interface: 'org.freedesktop.DBus',
        member: 'RequestName',
        values: [DBusString(name), DBusUint32(flags)]);
    return (result[0] as DBusUint32).value;
  }

  Future<int> releaseName(String name) async {
    var result = await callMethod(
        destination: 'org.freedesktop.DBus',
        path: '/org/freedesktop/DBus',
        interface: 'org.freedesktop.DBus',
        member: 'ReleaseName',
        values: [DBusString(name)]);
    return (result[0] as DBusUint32).value;
  }

  Future<List<String>> listNames() async {
    var result = await callMethod(
        destination: 'org.freedesktop.DBus',
        path: '/org/freedesktop/DBus',
        interface: 'org.freedesktop.DBus',
        member: 'ListNames');
    var names = List<String>();
    for (var name in (result[0] as DBusArray).children)
      names.add((name as DBusString).value);
    return names;
  }

  Future<List<String>> listActivatableNames() async {
    var result = await callMethod(
        destination: 'org.freedesktop.DBus',
        path: '/org/freedesktop/DBus',
        interface: 'org.freedesktop.DBus',
        member: 'ListActivatableNames');
    var names = List<String>();
    for (var name in (result[0] as DBusArray).children)
      names.add((name as DBusString).value);
    return names;
  }

  Future<bool> nameHasOwner(String name) async {
    var result = await callMethod(
        destination: 'org.freedesktop.DBus',
        path: '/org/freedesktop/DBus',
        interface: 'org.freedesktop.DBus',
        member: 'NameHasOwner',
        values: [DBusString(name)]);
    return (result[0] as DBusBoolean).value;
  }

  addMatch(String rule) async {
    await callMethod(
        destination: 'org.freedesktop.DBus',
        path: '/org/freedesktop/DBus',
        interface: 'org.freedesktop.DBus',
        member: 'AddMatch',
        values: [DBusString(rule)]);
  }

  removeMatch(String rule) async {
    await callMethod(
        destination: 'org.freedesktop.DBus',
        path: '/org/freedesktop/DBus',
        interface: 'org.freedesktop.DBus',
        member: 'RemoveMatch',
        values: [DBusString(rule)]);
  }

  Future<String> getId() async {
    var result = await callMethod(
        destination: 'org.freedesktop.DBus',
        path: '/org/freedesktop/DBus',
        interface: 'org.freedesktop.DBus',
        member: 'GetId');
    return (result[0] as DBusString).value;
  }

  peerPing(String destination, String path) async {
    await callMethod(
        destination: destination,
        path: path,
        interface: 'org.freedesktop.DBus.Peer',
        member: 'Ping');
  }

  Future<String> peerGetMachineId(String destination, String path) async {
    var result = await callMethod(
        destination: destination,
        path: path,
        interface: 'org.freedesktop.DBus.Peer',
        member: 'GetMachineId');
    return (result[0] as DBusString).value;
  }

  Future<String> introspect(String destination, String path) async {
    var result = await callMethod(
        destination: destination,
        path: path,
        interface: 'org.freedesktop.DBus.Introspectable',
        member: 'Introspect');
    return (result[0] as DBusString).value;
  }

  Future<DBusVariant> getProperty(
      {String destination, String path, String interface, String name}) async {
    var result = await callMethod(
        destination: destination,
        path: path,
        interface: 'org.freedesktop.DBus.Properties',
        member: 'Get',
        values: [DBusString(interface), DBusString(name)]);
    return result[0] as DBusVariant;
  }

  Future<DBusDict> getAllProperties(
      {String destination, String path, String interface}) async {
    var result = await callMethod(
        destination: destination,
        path: path,
        interface: 'org.freedesktop.DBus.Properties',
        member: 'GetAll',
        values: [DBusString(interface)]);
    return result[0] as DBusDict;
  }

  setProperty(
      {String destination,
      String path,
      String interface,
      String name,
      DBusVariant value}) async {
    await callMethod(
        destination: destination,
        path: path,
        interface: 'org.freedesktop.DBus.Properties',
        member: 'Set',
        values: [DBusString(interface), DBusString(name), value]);
  }

  Future<List<DBusValue>> callMethod(
      {String destination,
      String path,
      String interface,
      String member,
      List<DBusValue> values}) async {
    if (values == null) values = List<DBusValue>();
    _lastSerial++;
    var message = DBusMessage(
        type: MessageType.MethodCall,
        serial: _lastSerial,
        destination: destination,
        path: path,
        interface: interface,
        member: member,
        values: values);
    _sendMessage(message);

    var completer = Completer<List<DBusValue>>();
    _messageStream.listen((dynamic receivedData) {
      var m = receivedData as DBusMessage;
      if (m.replySerial == message.serial) {
        if (m.type == MessageType.Error)
          print('Error: ${m.errorName}'); // FIXME
        completer.complete(m.values);
      }
    });

    return completer.future;
  }

  _sendMessage(DBusMessage message) {
    var buffer = DBusWriteBuffer();
    message.marshal(buffer);
    _socket.write(buffer.data);
  }

  _authenticate() {
    var uid = _socket.sendCredentials();
    var uid_str = '';
    for (var c in uid.toString().runes)
      uid_str += c.toRadixString(16).padLeft(2);
    _socket.write(utf8.encode('AUTH\r\n'));
    print(utf8.decode(_socket.read(1024)));
    _socket.write(utf8.encode('AUTH EXTERNAL ${uid_str}\r\n'));
    print(utf8.decode(_socket.read(1024)));
    _socket.write(utf8.encode('BEGIN\r\n'));
  }
}

_read(ReadData _data) {
  var readBuffer = DBusReadBuffer();
  while (true) {
    var message = DBusMessage();
    var start = readBuffer.readOffset;
    if (!message.unmarshal(readBuffer)) {
      readBuffer.readOffset = start;
      var data = _data.socket.read(1024);
      readBuffer.writeBytes(data);
      continue;
    }
    readBuffer.flush();

    _data.port.send(message);
  }
}
