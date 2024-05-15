// Load an image and send it to a Colorlight 5A 75B receiver card

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:l2ethernet/l2ethernet.dart';
import 'package:image/image.dart';
import 'package:args/args.dart';

// My LED matrix size

const columnCount = 128;
const rowCount = 32;

const frame0101DataLength = 98;
const frame0107DataLength = 98;
const frame0affDataLength = 63;
const frame5500DataLength = columnCount * 3 + 7;
final frameData0101 = calloc<Uint8>(frame0101DataLength);
final frameData0107 = calloc<Uint8>(frame0107DataLength);
final frameData0aff = calloc<Uint8>(frame0affDataLength);
final frameData5500 = calloc<Uint8>(frame5500DataLength);

// Brightness (max 255 for both)

const brightnessMap = [
    [0, 0x00],
    [1, 0x03],
    [2, 0x05],
    [4, 0x0a],
    [5, 0x0d],
    [6, 0x0f],
    [10, 0x1a],
    [25, 0x40],
    [50, 0x80],
    [75, 0xbf],
    [100, 0xff]
];

int getBrightness(int brightnessPercent) {
  var brightness = 0x28;
  for (int i = 0; i < brightnessMap.length; ++i) {
    if (brightnessPercent >= brightnessMap[i][0]) {
      brightness = brightnessMap[i][1];
    }
  }
  return brightness;
}

void initFrames(brightnessPercent) {
  int brightness = getBrightness(brightnessPercent);

  // frameData0107[21] = brightnessPercent;
  // frameData0107[22] = 5;
  // frameData0107[24] = brightnessPercent;
  // frameData0107[25] = brightnessPercent;
  // frameData0107[26] = brightnessPercent;
  frameData0107[21] = brightness;
  frameData0107[22] = 5;
  frameData0107[24] = brightness;
  frameData0107[25] = brightness;
  frameData0107[26] = brightness;

  frameData0aff[0] = brightness;
  frameData0aff[1] = brightness;
  frameData0aff[2] = 255;

  frameData5500[0] = 0;
  frameData5500[1] = 0;
  frameData5500[2] = 0;
  frameData5500[3] = columnCount >> 8;
  frameData5500[4] = columnCount % 0xFF;
  frameData5500[5] = 0x08;
  frameData5500[6] = 0x88;
}

void frame5500fromImage(int row, Uint8List imageRow) {
  int lengthInPixels = (imageRow.length/3).toInt();
  int dummy_cols = columnCount - lengthInPixels;

//  print("Row: $row, lengthInPixels: $lengthInPixels dummy_cols: $dummy_cols");
  
  frameData5500[0] = row;
  for (int col = 0; col < dummy_cols; ++col) {
    frameData5500[7 + 3*col]     = 0x40;
    frameData5500[7 + 3*col + 1] = 0;
    frameData5500[7 + 3*col + 2] = 0;
  }

  for (int col = 0; col < lengthInPixels; ++col) {
    int out_col = dummy_cols + col;
    // NB: Our panel is BGR, not RGB!
    frameData5500[7 + 3*out_col + 2] = imageRow[3*col];
    frameData5500[7 + 3*out_col + 1] = imageRow[3*col + 1];
    frameData5500[7 + 3*out_col + 0] = imageRow[3*col + 2];
  }
  
  // for (int col = 0; col < columnCount; ++col) {
  //   // module image goes in top right corner
  //   print("Col: $col, bytes: ${imageRow.lengthInBytes}, len: ${imageRow.length}");
  //   if(col >= lengthInPixels && imageRow.length > 0) {
  //     frameData5500[7 + 3 * col] = imageRow[3 * (col - lengthInPixels)];
  //     frameData5500[7 + 3 * col + 1] = imageRow[3 * ((col - lengthInPixels) + 1)];
  //     frameData5500[7 + 3 * col + 2] = imageRow[3 * ((col - lengthInPixels) + 2)];
  //   } else {
  //     frameData5500[7 + 3 * col] = 0;
  //     frameData5500[7 + 3 * col + 1] = 0x40;
  //     frameData5500[7 + 3 * col + 2] = 0;
  //   }
  // }
}

/// Cleanup the buffers for the Ethernet frames
void deleteFrames() {
  calloc.free(frameData0107);
  calloc.free(frameData0aff);
  calloc.free(frameData5500);
  calloc.free(frameData0101);
}

/// Open the raw socket, make a sweep sequence, repeat 10 times
void main(List<String> args) async {
  var parser = ArgParser();
  parser.addOption('nic', help: "NIC name");
  parser.addOption('image', help: "Image name", defaultsTo: "");
  parser.addOption('brightness', help: "Brightness in %", defaultsTo: "1");
  parser.addFlag('resize', help: "Resize width to fit", defaultsTo: false);
  parser.addOption('text1', help: "Top text to display", defaultsTo: "");
  parser.addOption('text2', help: "Bottom text to display", defaultsTo: "");
  parser.addOption('module_size', help: "Size of individual modules", defaultsTo: "64");
  parser.addOption('output_mode', help: "Module write ordering (eg: r_to_l)", defaultsTo: "r_to_l");
  parser.addFlag('black', help: "Use black for text", defaultsTo: false);
  parser.addFlag('debug', help:"Debugging outputs", defaultsTo: false);

  var opts = parser.parse(args);
  print(args);

  var ethName = opts['nic'];
  var imageFile = opts['image'];
  var brightnessPercent = int.tryParse(opts['brightness']);
  var module_size = int.tryParse(opts['module_size']);
  bool resize = opts['resize'];
  String myText1 = opts['text1'];
  String myText2 = opts['text2'];
  bool black = opts['black'];

  if (ethName == null || imageFile == null || brightnessPercent == null) {
    print(parser.usage);
    exit(10);
  }

  var myl2eth = await L2Ethernet.setup(ethName);

  myl2eth.open();

  const src_mac = 0x222233445566;
  const dest_mac = 0x112233445566;

  initFrames(brightnessPercent);

  // Draw as many frames as you have columns (128 in my case),
  // one vertical white line from left to right
  // to see tearing or lack of smoothness

  var screenImage = await loadImage(imageFile, myText1, myText2,
    black, module_size, resize, opts['debug']);

  printImage(screenImage, myl2eth, src_mac, dest_mac, brightnessPercent,
    module_size, opts['debug']);
  myl2eth.close();
  deleteFrames();
}

const wait = true;

/// Load the image and send to the Colorlight 5A
///
Future<Image> loadImage(
    String imageFile,
    String text1,
    String text2,
    bool useBlack,
    int? module_size,
    bool resize,
    bool debug) async {
  int n;

  var image = Image(width: columnCount, height:rowCount);
  if (imageFile.isNotEmpty) {
    final imageOriginal = await decodeImageFile(imageFile);
    image = imageOriginal as Image;
  }

  // Examples how to draw circles and lines:
  // drawCircle(image, 64, 32, 30, 0x80ffffff);
  // drawLine(image, 10, 50, 120, 20, 0x8000ff00, thickness: 2, antialias: true);

  var textColor = ColorRgb8(255, 255, 255);
  if (useBlack) textColor = ColorRgb8(0, 0, 0);
  if (text2.isEmpty == "" && text1.isNotEmpty) {
    // drawString(image, text1, font: arial24,
    //     y: (rowCount - 24) ~/ 2, color: textColor);
    drawString(image, text1, font: arial14,
        y: 1, x: 1, color: textColor);
  } else {
    drawString(image, text1, font: arial24,
        y: (rowCount ~/ 2 - 24) ~/ 2, color: textColor);
    drawString(image, text2, font: arial24,
        y: (rowCount ~/ 2 - 24) ~/ 2 + rowCount ~/ 2, color: textColor);
  }

  if(resize) {
    image = copyResize(image,
      width: module_size as int, height: module_size as int);
  }
  print("Image: ${image.width} x ${image.height}, format: ${image.format}, channels: ${image.numChannels}");
  if(debug) {
    await encodePngFile('./resized.png', image);
  }

  return image;
}

Future<void>printImage(
  Image image,
  L2Ethernet l2,
  int src_mac,
  int dest_mac,
  int brightnessPercent,
  int? module_size,
  bool debug) async {

  int n;
  int brightness = getBrightness(brightnessPercent);

  // init packet?
  // n = l2.send(src_mac, dest_mac, 0x0101, frameData0101,
  //   frame0101DataLength, 0);

//  n = l2.send(src_mac, dest_mac, 0x0107, frameData0107, frame0107DataLength, 0);
  n = l2.send(src_mac, dest_mac, 0x0101, frameData0107, frame0107DataLength, 0);
  // Brightness setting
  n = l2.send(src_mac, dest_mac, 0x0a00 + brightness, frameData0aff,
      frame0affDataLength, 0);

  // Send one complete frame
  final imageData = image.getBytes(order: ChannelOrder.rgb);

  for (int y = 0; y < rowCount; ++y) {
    // return module_size bytes per row
    try {
      Uint8List part = Uint8List.view(imageData.buffer, y * 3 * image.width,
        3 * (module_size as int));
      frame5500fromImage(y, part);
      n = l2.send(
          src_mac, dest_mac, 0x5500, frameData5500, frame5500DataLength, 0);
    } on RangeError {
//      print("Out of image to display: $y");
      frame5500fromImage(y, Uint8List(0));
      n = l2.send(
          src_mac, dest_mac, 0x5500, frameData5500, frame5500DataLength, 0);
    }
  }

  // Without the following delay the end of the bottom row module flickers in the last line

  if (wait) await Future.delayed(Duration(milliseconds: 2));

  n = l2.send(src_mac, dest_mac, 0x0107, frameData0107, frame0107DataLength, 0);
}
  
