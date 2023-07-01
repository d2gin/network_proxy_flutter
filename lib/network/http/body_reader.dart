import 'dart:math';
import 'dart:typed_data';

import 'package:network_proxy/network/http/http.dart';

import '../../utils/num.dart';
import '../channel.dart';
import 'codec.dart';

class Result {
  final bool isDone;
  Uint8List? body;

  Result(this.isDone, {this.body});
}

class BodyReader {
  final HttpMessage message;

  // BytesBuilder msgBytes = BytesBuilder();
  int _offset = 0;
  ReaderState _state;

  final BytesBuilder _bodyBuffer = BytesBuilder();

  ///chunked编码 剩余未读取的chunk大小
  int _chunkReadableSize = 0;

  BodyReader(this.message)
      : _state = message.headers.isChunked ? ReaderState.readChunkSize : ReaderState.readFixedLengthContent;

  Result readBody(Uint8List data) {
    if (_bodyBuffer.length > Codec.maxBodyLength) {
      _bodyBuffer.clear();
      throw Exception('Body length exceeds ${Codec.maxBodyLength}');
    }

    _offset = 0;

    //chunked编码
    if (message.headers.isChunked) {
      _readChunked(data);
    } else {
      _readFixedLengthContent(data);
    }

    if (_state == ReaderState.done) {
      var body = _bodyBuffer.toBytes();
      _bodyBuffer.clear();
      return Result(true, body: body);
    }

    return Result(false);
  }

  void _readFixedLengthContent(Uint8List data) {
    if (message.contentLength > 0) {
      _bodyBuffer.add(data.sublist(_offset));
    }

    if (message.contentLength == -1 || _bodyBuffer.length >= message.contentLength) {
      _state = ReaderState.done;

      if (message.contentLength != -1 && _bodyBuffer.length > message.contentLength) {
        print(String.fromCharCodes(_bodyBuffer.toBytes().sublist(message.contentLength)));
      }
    }
  }

  void _readChunked(Uint8List data) {
    while (_offset < data.length) {
      //读取chunk length
      if (_state == ReaderState.readChunkSize) {
        _chunkReadableSize = _readChunkSize(data);

        if (_chunkReadableSize == 0) {
          //chunked编码结束
          _state = ReaderState.done;
          break;
        }

        if (_chunkReadableSize == -1) {
          continue;
        }
        _state = ReaderState.readChunkedContent;
      }

      //读取chunk内容
      if (_state == ReaderState.readChunkedContent) {
        int end = min(data.length, _offset + _chunkReadableSize);
        _bodyBuffer.add(data.sublist(_offset, end));

        //可读大小
        _chunkReadableSize -= (end - _offset);
        _offset = end;
        if (_chunkReadableSize == 0) {
          _state = ReaderState.readChunkSize;
          _offset += 2; //内容结尾\r\n
        }
      }
    }
  }

  int _readChunkSize(Uint8List data) {
    if (_offset >= data.length) {
      return -1;
    }

    for (int i = _offset; i < data.length; i++) {
      /// chunked编码内容结尾\r\n
      if (data[i] == HttpConstants.lf) {
        if (i > 0 && data[i - 1] == HttpConstants.cr) {
          var line = data.sublist(_offset, i - 1);
          _offset = i + 1;
          if (line.isEmpty) {
            return -1;
          }
          return hexToInt(String.fromCharCodes(line));
        }

        //可能上个包是结尾\r 最好做法是缓存上个不完整的包，先临时处理下
        if (data.length == 1) {
          _offset = i + 1;
          return -1;
        }
      }
    }

    throw Exception('Invalid chunked encoding line: ${String.fromCharCodes(data)}');
  }
}

enum ReaderState { readFixedLengthContent, readChunked, readChunkSize, readChunkedContent, done }
