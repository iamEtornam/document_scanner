import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:dmrtd/dmrtd.dart';
import 'package:dmrtd/extensions.dart';
import 'package:expandable/expandable.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mrz_scanner/flutter_mrz_scanner.dart';
import 'package:image/image.dart' as img;
import 'package:mrz_parser/mrz_parser.dart';
import 'package:passport_reader_app/utils.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  MRZResult? mrzResult;
  String _alertMessage = "";
  bool _isNfcAvailable = false;
  bool _isReading = false;

  // mrz data
  String get _docNumber => mrzResult!.documentNumber;

  MrtdData? _mrtdData;

  final NfcProvider _nfc = NfcProvider();
  // ignore: unused_field
  late Timer _timerStateUpdater;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    _initPlatformState();

    // Update platform state every 3 sec
    _timerStateUpdater = Timer.periodic(const Duration(seconds: 3), (Timer t) {
      _initPlatformState();
    });
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> _initPlatformState() async {
    bool isNfcAvailable;
    try {
      NfcStatus status = await NfcProvider.nfcStatus;
      isNfcAvailable = status == NfcStatus.enabled;
    } on PlatformException {
      isNfcAvailable = false;
    }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    if (!mounted) return;

    setState(() {
      _isNfcAvailable = isNfcAvailable;
    });
  }

  DateTime? _getDOBDate() {
    if (mrzResult?.birthDate == null) {
      return null;
    }
    return mrzResult?.birthDate;
  }

  DateTime? _getDOEDate() {
    if (mrzResult?.expiryDate == null) {
      return null;
    }
    return mrzResult?.expiryDate;
  }

  void _readMRTD() async {
    try {
      setState(() {
        _mrtdData = null;
        _alertMessage = "Waiting for Passport tag ...";
        _isReading = true;
      });

      await _nfc.connect(
          iosAlertMessage: "Hold your phone near Biometric Passport");
      final passport = Passport(_nfc);

      setState(() {
        _alertMessage = "Reading Passport ...";
      });

      _nfc.setIosAlertMessage("Trying to read EF.CardAccess ...");
      final mrtdData = MrtdData();

      try {
        mrtdData.cardAccess = await passport.readEfCardAccess();
      } on PassportError {
        //if (e.code != StatusWord.fileNotFound) rethrow;
      }

      _nfc.setIosAlertMessage("Trying to read EF.CardSecurity ...");

      try {
        mrtdData.cardSecurity = await passport.readEfCardSecurity();
      } on PassportError {
        //if (e.code != StatusWord.fileNotFound) rethrow;
      }

      _nfc.setIosAlertMessage("Initiating session ...");
      final bacKeySeed = DBAKeys(_docNumber, _getDOBDate()!, _getDOEDate()!);
      await passport.startSession(bacKeySeed);

      _nfc.setIosAlertMessage(formatProgressMsg("Reading EF.COM ...", 0));
      mrtdData.com = await passport.readEfCOM();

      _nfc.setIosAlertMessage(formatProgressMsg("Reading Data Groups ...", 20));

      if (mrtdData.com!.dgTags.contains(EfDG1.TAG)) {
        mrtdData.dg1 = await passport.readEfDG1();
      }

      if (mrtdData.com!.dgTags.contains(EfDG2.TAG)) {
        mrtdData.dg2 = await passport.readEfDG2();
        log("DG2 read successfully. Contains image data: ${mrtdData.dg2!.imageData != null}");
        if (mrtdData.dg2!.imageData != null) {
          log("Image data length: ${mrtdData.dg2!.imageData!.length}");
          log("Image type: ${mrtdData.dg2!.imageType}");

          // Try to identify JP2 format
          final imageData = mrtdData.dg2!.imageData!;
          if (imageData.length > 8) {
            if ((imageData[0] == 0x00 &&
                    imageData[1] == 0x00 &&
                    imageData[2] == 0x00 &&
                    imageData[3] == 0x0C) ||
                (imageData[0] == 0xFF &&
                    imageData[1] == 0x4F &&
                    imageData[2] == 0xFF &&
                    imageData[3] == 0x51)) {
              log("Detected JPEG2000 format. Flutter can't natively display this format.");

              // Save it for debugging
              _saveImageForDebug(imageData);
            } else {
              // Scan for JPEG header (FF D8 FF)
              for (int i = 0; i < imageData.length - 3; i++) {
                if (imageData[i] == 0xFF &&
                    imageData[i + 1] == 0xD8 &&
                    imageData[i + 2] == 0xFF) {
                  log("Found embedded JPEG at offset $i");
                  mrtdData.dg2!.imageData = imageData.sublist(i);
                  break;
                }
              }
            }
          }
        }
      }

      // To read DG3 and DG4 session has to be established with CVCA certificate (not supported).
      // if(mrtdData.com!.dgTags.contains(EfDG3.TAG)) {
      //   mrtdData.dg3 = await passport.readEfDG3();
      // }

      // if(mrtdData.com!.dgTags.contains(EfDG4.TAG)) {
      //   mrtdData.dg4 = await passport.readEfDG4();
      // }

      if (mrtdData.com!.dgTags.contains(EfDG5.TAG)) {
        mrtdData.dg5 = await passport.readEfDG5();
      }

      if (mrtdData.com!.dgTags.contains(EfDG6.TAG)) {
        mrtdData.dg6 = await passport.readEfDG6();
      }

      if (mrtdData.com!.dgTags.contains(EfDG7.TAG)) {
        mrtdData.dg7 = await passport.readEfDG7();
      }

      if (mrtdData.com!.dgTags.contains(EfDG8.TAG)) {
        mrtdData.dg8 = await passport.readEfDG8();
      }

      if (mrtdData.com!.dgTags.contains(EfDG9.TAG)) {
        mrtdData.dg9 = await passport.readEfDG9();
      }

      if (mrtdData.com!.dgTags.contains(EfDG10.TAG)) {
        mrtdData.dg10 = await passport.readEfDG10();
      }

      if (mrtdData.com!.dgTags.contains(EfDG11.TAG)) {
        mrtdData.dg11 = await passport.readEfDG11();
      }

      if (mrtdData.com!.dgTags.contains(EfDG12.TAG)) {
        mrtdData.dg12 = await passport.readEfDG12();
      }

      if (mrtdData.com!.dgTags.contains(EfDG13.TAG)) {
        mrtdData.dg13 = await passport.readEfDG13();
      }

      if (mrtdData.com!.dgTags.contains(EfDG14.TAG)) {
        mrtdData.dg14 = await passport.readEfDG14();
      }

      if (mrtdData.com!.dgTags.contains(EfDG15.TAG)) {
        mrtdData.dg15 = await passport.readEfDG15();
        _nfc.setIosAlertMessage(formatProgressMsg("Doing AA ...", 60));
        mrtdData.aaSig = await passport.activeAuthenticate(Uint8List(8));
      }

      if (mrtdData.com!.dgTags.contains(EfDG16.TAG)) {
        mrtdData.dg16 = await passport.readEfDG16();
      }

      _nfc.setIosAlertMessage(formatProgressMsg("Reading EF.SOD ...", 80));
      mrtdData.sod = await passport.readEfSOD();

      setState(() {
        _mrtdData = mrtdData;
      });

      setState(() {
        _alertMessage = "";
      });

      _scrollController.animateTo(300.0,
          duration: const Duration(milliseconds: 500), curve: Curves.ease);
    } on Exception catch (e) {
      final se = e.toString().toLowerCase();
      String alertMsg = "An error has occurred while reading Passport!";
      if (e is PassportError) {
        if (se.contains("security status not satisfied")) {
          alertMsg =
              "Failed to initiate session with passport.\nCheck input data!";
        }
        log("PassportError: ${e.message}");
      } else {
        log("An exception was encountered while trying to read Passport: $e");
      }

      if (se.contains('timeout')) {
        alertMsg = "Timeout while waiting for Passport tag";
      } else if (se.contains("tag was lost")) {
        alertMsg = "Tag was lost. Please try again!";
      } else if (se.contains("invalidated by user")) {
        alertMsg = "";
      }

      setState(() {
        _alertMessage = alertMsg;
      });
    } finally {
      if (_alertMessage.isNotEmpty) {
        await _nfc.disconnect(iosErrorMessage: _alertMessage);
      } else {
        await _nfc.disconnect(
            iosAlertMessage: formatProgressMsg("Finished", 100));
      }
      setState(() {
        _isReading = false;
      });
    }
  }

  bool disabledInput() {
    return _isReading || !_isNfcAvailable;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Scanner POC'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (mrzResult == null) ...{
                Text(
                  'Use the camera button to scan the machine readable zone (MRZ) of a biometric passport or ID card',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              } else ...{
                Text(
                  'Read Passport information using NFC',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: disabledInput() ? null : _readMRTD,
                  child: Text(
                      _isReading ? 'Reading...' : 'Read Passport with NFC'),
                ),
                _buildPage(context)
              }
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final res = await Navigator.of(context).push(
              CupertinoPageRoute(builder: (context) => const MrzScannerView()));
          if (res == null) return;
          setState(() {
            mrzResult = res;
          });
        },
        tooltip: 'Scan',
        child: const Icon(Icons.camera),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    return Material(
        child: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: SingleChildScrollView(
                    controller: _scrollController,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          const SizedBox(height: 20),
                          Row(children: <Widget>[
                            const Text('NFC available:',
                                style: TextStyle(
                                    fontSize: 18.0,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(width: 4),
                            Text(_isNfcAvailable ? "Yes" : "No",
                                style: const TextStyle(fontSize: 18.0))
                          ]),
                          const SizedBox(height: 20),
                          if (_alertMessage.isNotEmpty)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8.0),
                              child: Text(_alertMessage,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 15.0,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red)),
                            ),
                          if (_mrtdData?.dg2 != null) _buildPassportPhoto(),
                          const SizedBox(height: 15),
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                      _mrtdData != null ? "Passport Data:" : "",
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          fontSize: 15.0,
                                          fontWeight: FontWeight.bold)),
                                  Padding(
                                      padding: const EdgeInsets.only(
                                          left: 16.0, top: 8.0, bottom: 8.0),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: _mrtdDataWidgets()))
                                ]),
                          ),
                        ])))));
  }

  Widget _buildPassportPhoto() {
    if (_mrtdData?.dg2 == null) return const SizedBox.shrink();

    try {
      final dg2 = _mrtdData!.dg2!;
      log("In _buildPassportPhoto: dg2 has imageData: ${dg2.imageData != null}");

      if (dg2.imageData == null) {
        return const Text('No passport photo available',
            style: TextStyle(color: Colors.red));
      }

      log("Image data length: ${dg2.imageData!.length}, image type: ${dg2.imageType}");

      // Debug: Check first few bytes to determine image format
      if (dg2.imageData!.length > 20) {
        String hexBytes = dg2.imageData!
            .sublist(0, 20)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(' ');
        log("First 20 bytes of image data: $hexBytes");
      }

      // Try to determine if the image is a standard JPEG
      bool isJpeg = false;
      if (dg2.imageData!.length > 3) {
        // Check for JPEG signature (SOI marker): FF D8 FF
        if (dg2.imageData![0] == 0xFF &&
            dg2.imageData![1] == 0xD8 &&
            dg2.imageData![2] == 0xFF) {
          isJpeg = true;
          log("Image appears to be a valid JPEG format");
        } else {
          log("Image does not have JPEG signature. This could be JP2 or other format.");

          // Let's try to clean up the data - sometimes the image data contains extra header info
          // Try to find the JPEG header (FF D8) in the data
          for (int i = 0; i < dg2.imageData!.length - 3; i++) {
            if (dg2.imageData![i] == 0xFF &&
                dg2.imageData![i + 1] == 0xD8 &&
                dg2.imageData![i + 2] == 0xFF) {
              log("Found JPEG signature at offset $i");
              // Extract just the image part
              Uint8List jpegData = dg2.imageData!.sublist(i);
              log("Extracted JPEG data length: ${jpegData.length}");

              // Try to display this extracted JPEG
              return _buildPhotoWidget(jpegData, true);
            }
          }
        }
      }

      // If we identified a JPEG or couldn't extract one, use the standard approach
      return _buildPhotoWidget(dg2.imageData!, isJpeg);
    } catch (e) {
      log('Error displaying passport photo: $e');
      return Text('Failed to extract passport photo: $e',
          style: const TextStyle(color: Colors.red));
    }
  }

  Widget _buildPhotoWidget(Uint8List imageData, bool isJpeg) {
    Widget imageWidget;

    if (isJpeg) {
      // It's a standard JPEG, we can use Image.memory directly
      imageWidget = Image.memory(
        imageData,
        height: 200,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          log("Error rendering JPEG image: $error");
          return const Center(
            child: Text(
              "Error rendering image",
              style: TextStyle(color: Colors.red),
            ),
          );
        },
      );
    } else {
      // For JPEG2000 or unknown formats
      try {
        // Try to decode as a generic image first
        final decodedImage = img.decodeImage(imageData);
        if (decodedImage != null) {
          log("Successfully decoded image with dimensions: ${decodedImage.width}x${decodedImage.height}");

          // Convert to PNG format
          final pngData = img.encodePng(decodedImage);

          imageWidget = Image.memory(
            Uint8List.fromList(pngData),
            height: 200,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              log("Error rendering converted image: $error");
              return _buildUnsupportedFormatWidget(imageData);
            },
          );
        } else {
          log("Failed to decode image with image package");
          imageWidget = _buildUnsupportedFormatWidget(imageData);
        }
      } catch (e) {
        log("Error decoding image: $e");
        imageWidget = _buildUnsupportedFormatWidget(imageData);
      }
    }

    return Column(
      children: [
        const Text('Passport Photo',
            style: TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            borderRadius: BorderRadius.circular(8),
          ),
          child: imageWidget,
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildUnsupportedFormatWidget(Uint8List imageData) {
    return Container(
      height: 200,
      color: Colors.grey[200],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            "Image format not supported\n(possibly JPEG2000)",
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () {
              _saveImageForDebug(imageData);
            },
            child: const Text("Save Image for Debug"),
          ),
        ],
      ),
    );
  }

  Future<void> _saveImageForDebug(Uint8List imageData) async {
    try {
      final directory = Directory('/tmp');
      final path = '${directory.path}/passport_image_debug.bin';

      final file = File(path);
      await file.writeAsBytes(imageData);

      log("Saved image data to $path for debugging");
    } catch (e) {
      log("Error saving image data: $e");
    }
  }

  Widget _makeMrtdDataWidget(
      {required String header,
      required String collapsedText,
      required dataText}) {
    return ExpandablePanel(
        theme: const ExpandableThemeData(
          headerAlignment: ExpandablePanelHeaderAlignment.center,
          tapBodyToCollapse: true,
          hasIcon: true,
          iconColor: Colors.red,
        ),
        header: Text(header),
        collapsed: Text(collapsedText,
            softWrap: true, maxLines: 2, overflow: TextOverflow.ellipsis),
        expanded: Container(
            padding: const EdgeInsets.all(18),
            color: const Color.fromARGB(255, 239, 239, 239),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextButton(
                    child: const Text('Copy'),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: dataText)),
                  ),
                  SelectableText(dataText, textAlign: TextAlign.left)
                ])));
  }

  List<Widget> _mrtdDataWidgets() {
    List<Widget> list = [];
    if (_mrtdData == null) return list;

    if (_mrtdData!.cardAccess != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.CardAccess',
          collapsedText: '',
          dataText: _mrtdData!.cardAccess!.toBytes().hex()));
    }

    if (_mrtdData!.cardSecurity != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.CardSecurity',
          collapsedText: '',
          dataText: _mrtdData!.cardSecurity!.toBytes().hex()));
    }

    if (_mrtdData!.sod != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.SOD',
          collapsedText: '',
          dataText: _mrtdData!.sod!.toBytes().hex()));
    }

    if (_mrtdData!.com != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.COM',
          collapsedText: '',
          dataText: formatEfCom(_mrtdData!.com!)));
    }

    if (_mrtdData!.dg1 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG1',
          collapsedText: '',
          dataText: formatMRZ(_mrtdData!.dg1!.mrz)));
    }

    if (_mrtdData!.dg2 != null) {
      String dg2Info = _mrtdData!.dg2!.toBytes().hex();

      // Add additional information about the image data if available
      if (_mrtdData!.dg2!.imageData != null) {
        dg2Info += "\n\nImage Data Information:";
        dg2Info += "\nImage Type: ${_mrtdData!.dg2!.imageType}";
        dg2Info +=
            "\nImage Data Length: ${_mrtdData!.dg2!.imageData!.length} bytes";
        dg2Info += "\nImage Width: ${_mrtdData!.dg2!.imageWidth}";
        dg2Info += "\nImage Height: ${_mrtdData!.dg2!.imageHeight}";
        dg2Info += "\nImage Color Space: ${_mrtdData!.dg2!.imageColorSpace}";
        dg2Info += "\nSource Type: ${_mrtdData!.dg2!.sourceType}";

        // Check first bytes to determine format
        if (_mrtdData!.dg2!.imageData!.length > 4) {
          final firstBytes = _mrtdData!.dg2!.imageData!.sublist(0, 4);
          dg2Info +=
              "\nFirst 4 bytes (hex): ${firstBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}";

          // Check if it's a standard JPEG (starts with FF D8 FF)
          if (firstBytes[0] == 0xFF &&
              firstBytes[1] == 0xD8 &&
              firstBytes[2] == 0xFF) {
            dg2Info +=
                "\nFormat: Standard JPEG (identified by FF D8 FF signature)";
          }
          // Check if it's a JPEG2000 (starts with 00 00 00 0C or FF 4F FF 51)
          else if ((firstBytes[0] == 0x00 &&
                  firstBytes[1] == 0x00 &&
                  firstBytes[2] == 0x00 &&
                  firstBytes[3] == 0x0C) ||
              (firstBytes[0] == 0xFF &&
                  firstBytes[1] == 0x4F &&
                  firstBytes[2] == 0xFF &&
                  firstBytes[3] == 0x51)) {
            dg2Info += "\nFormat: Likely JPEG2000 (identified by signature)";
          } else {
            dg2Info += "\nFormat: Unknown image format";
          }
        }
      } else {
        dg2Info += "\n\nNo image data available";
      }

      list.add(_makeMrtdDataWidget(
          header: 'EF.DG2',
          collapsedText: 'Facial Image Data',
          dataText: dg2Info));
    }

    if (_mrtdData!.dg3 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG3',
          collapsedText: '',
          dataText: _mrtdData!.dg3!.toBytes().hex()));
    }

    if (_mrtdData!.dg4 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG4',
          collapsedText: '',
          dataText: _mrtdData!.dg4!.toBytes().hex()));
    }

    if (_mrtdData!.dg5 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG5',
          collapsedText: '',
          dataText: _mrtdData!.dg5!.toBytes().hex()));
    }

    if (_mrtdData!.dg6 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG6',
          collapsedText: '',
          dataText: _mrtdData!.dg6!.toBytes().hex()));
    }

    if (_mrtdData!.dg7 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG7',
          collapsedText: '',
          dataText: _mrtdData!.dg7!.toBytes().hex()));
    }

    if (_mrtdData!.dg8 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG8',
          collapsedText: '',
          dataText: _mrtdData!.dg8!.toBytes().hex()));
    }

    if (_mrtdData!.dg9 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG9',
          collapsedText: '',
          dataText: _mrtdData!.dg9!.toBytes().hex()));
    }

    if (_mrtdData!.dg10 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG10',
          collapsedText: '',
          dataText: _mrtdData!.dg10!.toBytes().hex()));
    }

    if (_mrtdData!.dg11 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG11',
          collapsedText: '',
          dataText: _mrtdData!.dg11!.toBytes().hex()));
    }

    if (_mrtdData!.dg12 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG12',
          collapsedText: '',
          dataText: _mrtdData!.dg12!.toBytes().hex()));
    }

    if (_mrtdData!.dg13 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG13',
          collapsedText: '',
          dataText: _mrtdData!.dg13!.toBytes().hex()));
    }

    if (_mrtdData!.dg14 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG14',
          collapsedText: '',
          dataText: _mrtdData!.dg14!.toBytes().hex()));
    }

    if (_mrtdData!.dg15 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG15',
          collapsedText: '',
          dataText: _mrtdData!.dg15!.toBytes().hex()));
    }

    if (_mrtdData!.aaSig != null) {
      list.add(_makeMrtdDataWidget(
          header: 'Active Authentication signature',
          collapsedText: '',
          dataText: _mrtdData!.aaSig!.hex()));
    }

    if (_mrtdData!.dg16 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG16',
          collapsedText: '',
          dataText: _mrtdData!.dg16!.toBytes().hex()));
    }

    return list;
  }
}

class MrzScannerView extends StatefulWidget {
  const MrzScannerView({super.key});

  @override
  State<MrzScannerView> createState() => _MrzScannerViewState();
}

class _MrzScannerViewState extends State<MrzScannerView> {
  bool isParsed = false;
  MRZController? controller;
  MRZResult? mrzResult;

  @override
  void dispose() {
    controller?.stopPreview();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: MRZScanner(
        withOverlay: true, // optional overlay
        onControllerCreated: (controller) => onControllerCreated(controller),
      ),
    );
  }

  void onControllerCreated(MRZController controller) {
    this.controller = controller;
    controller.onParsed = (result) async {
      if (isParsed) {
        return;
      }
      isParsed = true;
      log('onParsed: ${result.toString()}');
      final res = await showDialog(
          context: context,
          builder: (context) => AlertDialog(
                  content: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('Document type: ${result.documentType}'),
                  Text('Country: ${result.countryCode}'),
                  Text('Surnames: ${result.surnames}'),
                  Text('Given names: ${result.givenNames}'),
                  Text('Document number: ${result.documentNumber}'),
                  Text('Nationality code: ${result.nationalityCountryCode}'),
                  Text('Birthdate: ${result.birthDate}'),
                  Text('Sex: ${result.sex}'),
                  Text('Expriy date: ${result.expiryDate}'),
                  Text('Personal number: ${result.personalNumber}'),
                  Text('Personal number 2: ${result.personalNumber2}'),
                  ElevatedButton(
                    child: const Text('ok'),
                    onPressed: () {
                      isParsed = false;
                      return Navigator.pop(context, result);
                    },
                  ),
                ],
              )));

      if (res! is MRZResult) return;
      if (!mounted) return;
      Navigator.pop(context, res);
    };
    controller.onError = (error) => log(error);

    controller.startPreview();
  }
}
