import 'dart:async';
import 'dart:developer';

import 'package:dmrtd/dmrtd.dart';
import 'package:dmrtd/extensions.dart';
import 'package:expandable/expandable.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mrz_scanner/flutter_mrz_scanner.dart';
import 'package:intl/intl.dart';
import 'package:mrz_parser/mrz_parser.dart';
import 'package:passport_reader_app/utils.dart';
import 'package:permission_handler/permission_handler.dart';

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
      home: FutureBuilder<PermissionStatus>(
          future: Permission.camera.request(),
          builder: (context, snapshot) {
            if (snapshot.hasData && snapshot.data == PermissionStatus.granted) {
              return const MyHomePage();
            }
            if (snapshot.data == PermissionStatus.permanentlyDenied) {
              // The user opted to never again see the permission request dialog for this
              // app. The only way to change the permission's status now is to let the
              // user manually enable it in the system settings.
              openAppSettings();
            }

            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text('Awaiting for permissions'),
                    ),
                    Text('Current status: ${snapshot.data?.toString()}'),
                  ],
                ),
              ),
            );
          }),
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
  final _mrzData = GlobalKey<FormState>();

  // mrz data
  String get _docNumber => mrzResult!.documentNumber;
  DateTime get _dob => mrzResult!.birthDate; // date of birth
  DateTime get _doe => mrzResult!.expiryDate; // date of doc expiry

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

  Future<String?> _pickDate(BuildContext context, DateTime firstDate,
      DateTime initDate, DateTime lastDate) async {
    final locale = Localizations.localeOf(context);
    final DateTime? picked = await showDatePicker(
        context: context,
        firstDate: firstDate,
        initialDate: initDate,
        lastDate: lastDate,
        locale: locale);

    if (picked != null) {
      return DateFormat.yMd().format(picked);
    }
    return null;
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
                TextButton(onPressed: () async {}, child: const Text('Read')),
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
                          const SizedBox(height: 40),
                          // _buildForm(context),
                          const SizedBox(height: 20),
                          ElevatedButton(
                            // btn Read MRTD
                            onPressed: disabledInput() ||
                                    !_mrzData.currentState!.validate()
                                ? null
                                : _readMRTD,
                            child: Text(
                                _isReading ? 'Reading ...' : 'Read Passport'),
                          ),
                          const SizedBox(height: 4),
                          Text(_alertMessage,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 15.0, fontWeight: FontWeight.bold)),
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
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG2',
          collapsedText: '',
          dataText: _mrtdData!.dg2!.toBytes().hex()));
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
