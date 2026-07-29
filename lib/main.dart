import 'dart:async';
import 'dart:convert';

import 'package:EBiCS/localParams.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'LEV_Pages.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'EBiCS',
        theme: ThemeData(
          primarySwatch: Colors.lightBlue,
        ),
        home: const MyHomePage(title: 'v.01'),
      );
}

class MyHomePage extends StatefulWidget {
  MyHomePage({super.key, required this.title});

  final String title;
  final List<BluetoothDevice> devicesList = <BluetoothDevice>[];
  final Map<Guid, List<int>> readValues = <Guid, List<int>>{};
  Map<String, dynamic> mapJSON = {};

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  final _writeController = TextEditingController();
  final String SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb";
  final String CHARACTERISTIC_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb";
  final String TARGET_DEVICE_NAME = "EBiCS";

  BluetoothDevice? _connectedDevice;
  BluetoothDevice? targetDevice;
  List<BluetoothService> _services = [];

  static int viewNumber = 2;
  static Color BT_color = Colors.grey;
  static Color OnOff_color = Colors.grey;
  static bool OnOff = false;

  BluetoothCharacteristic? UART_characteristic;
  controllerState CS = controllerState(0);
  localParams LP = localParams(0);

  late File jsonFile;
  String fileName = "myJSONFile.json";
  bool fileExists = false;
  Timer? timer;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  Future<void> loadParams() async {
    jsonFile.writeAsStringSync(await rootBundle.loadString("assets/params.json"));

    setState(() {
      widget.mapJSON = Map.castFrom(json.decode(jsonFile.readAsStringSync()) as Map);
      debugPrint('jasonFile Inhalt nach loadParams: ${widget.mapJSON}');
    });
  }

  void safeParams() {
    assignMap_LP(widget.mapJSON, LP);
    assignMap_CS(widget.mapJSON, CS);
    jsonFile.writeAsStringSync(json.encode(widget.mapJSON));

    setState(() {
      widget.mapJSON = Map.castFrom(json.decode(jsonFile.readAsStringSync()) as Map);
      debugPrint('jasonFile Inhalt nach safeParams: ${widget.mapJSON}');
    });
  }

  void _addDeviceTolist(final BluetoothDevice device) {
    if (!widget.devicesList.contains(device)) {
      setState(() {
        widget.devicesList.add(device);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      setState(() {
        LP.trip += CS.Speed.toDouble() / 36000; //sum up distance from speed
      });
    });
    initCS();
    initLP();
    processJSON();

    for (final device in FlutterBluePlus.connectedDevices) {
      _addDeviceTolist(device);
    }

    _scanSubscription = FlutterBluePlus.scanResults.listen((List<ScanResult> results) {
      for (ScanResult result in results) {
        _addDeviceTolist(result.device);
        if (result.device.platformName == TARGET_DEVICE_NAME) {
          targetDevice = result.device;
          connectToDevice();
        }
      }
    });
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    _scanSubscription?.cancel();
    _writeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        safeParams();
        debugPrint('App-Status $state');
        break;
      case AppLifecycleState.inactive:
        safeParams();
        debugPrint('App-Status $state');
        break;
      case AppLifecycleState.paused:
        safeParams();
        debugPrint('App-Status $state');
        break;
      default:
        break;
    }
  }

  Future<void> processJSON() async {
    final Directory extDir = await getApplicationDocumentsDirectory();
    jsonFile = File('${extDir.path}/$fileName');
    fileExists = jsonFile.existsSync();
    debugPrint('jasonFile File existiert: $fileExists');

    if (fileExists) {
      setState(() {
        widget.mapJSON = json.decode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
        debugPrint('jasonFile Inhalt: ${widget.mapJSON}');
        assignJSON_CS(widget.mapJSON, CS);
        assignJSON_LP(widget.mapJSON, LP);
      });
    } else {
      jsonFile.createSync();
      fileExists = jsonFile.existsSync();
      await loadParams();
      setState(() {
        widget.mapJSON = json.decode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
      });
    }
  }

  Future<void> connectToDevice() async {
    final device = targetDevice;
    if (device == null) return;

    await FlutterBluePlus.stopScan();
    try {
      await device.connect();
    } catch (e) {
      debugPrint('Connect error: $e');
    } finally {
      _services = await device.discoverServices();
    }
    await activateNotify();
    setState(() {
      _connectedDevice = device;
      viewNumber = 1;
      BT_color = Colors.green[900]!;
    });
    debugPrint('DEVICE CONNECTED');
  }

  Future<void> activateNotify() async {
    for (BluetoothService service in _services) {
      if (service.uuid.toString() == SERVICE_UUID) {
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == CHARACTERISTIC_UUID) {
            UART_characteristic = characteristic;
            await characteristic.setNotifyValue(true);
            characteristic.lastValueStream.listen((value) {
              setState(() {
                widget.readValues[characteristic.uuid] = value;
                CS = processRxAnt(value, CS);
              });
            });
          }
        }
      }
    }
  }

  ListView _buildListViewOfDevices() {
    List<Container> containers = [];
    for (BluetoothDevice device in widget.devicesList) {
      containers.add(
        Container(
          height: 50,
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  children: <Widget>[
                    Text(device.platformName.isEmpty ? '(unknown device)' : device.platformName),
                    Text(device.remoteId.toString()),
                  ],
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(backgroundColor: Colors.blue),
                child: const Text('Connect', style: TextStyle(color: Colors.white)),
                onPressed: () async {
                  LP.deviceName = device.platformName;
                  await FlutterBluePlus.stopScan();
                  try {
                    await device.connect();
                  } catch (e) {
                    debugPrint('Connect error: $e');
                  } finally {
                    _services = await device.discoverServices();
                  }
                  setState(() {
                    _connectedDevice = device;
                  });
                },
              ),
            ],
          ),
        ),
      );
    }
    containers.add(
      Container(
        height: 50,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            TextButton(
              style: TextButton.styleFrom(backgroundColor: Colors.blue),
              child: const Text('Detail View', style: TextStyle(color: Colors.white)),
              onPressed: () {
                setState(() {
                  viewNumber = 1;
                });
              },
            ),
            TextButton(
              style: TextButton.styleFrom(backgroundColor: Colors.blue),
              child: const Text('Save Settings', style: TextStyle(color: Colors.white)),
              onPressed: () {
                safeParams();
              },
            ),
          ],
        ),
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(8),
      children: <Widget>[
        ...containers,
      ],
    );
  }

  ListView _buildConnectDeviceView() {
    List<Container> containers = [];

    containers.add(
      Container(
        height: 300,
        child: MyGauge(CS.Speed.toDouble() / 10),
      ),
    );

    containers.add(
      Container(
        child: Row(
          children: <Widget>[
            MyBox(Colors.white, height: 22, text: "Trip"),
            MyBox(Colors.white, height: 22, text: "Voltage"),
            MyBox(Colors.white, height: 22, text: "Power"),
          ],
        ),
      ),
    );
    containers.add(
      Container(
        child: Row(
          children: <Widget>[
            MyBox(mediumBlue, height: 30, fontColor: Colors.white, text: '${LP.trip.toStringAsFixed(1)} km'),
            MyBox(mediumBlue, height: 30, fontColor: Colors.white, text: '${(CS.Battery_Voltage / 4).toStringAsFixed(1)} V'),
            MyBox(mediumBlue,
                height: 30,
                fontColor: Colors.white,
                text: '${(CS.Fuel_Consumption / 100 * CS.Battery_Voltage / 4).toStringAsFixed(0)} W'),
          ],
        ),
      ),
    );

    containers.add(
      Container(
        child: Row(
          children: <Widget>[
            MyBox(Colors.white, height: 22, text: ""),
            MyBox(Colors.white, height: 22, text: "Regen Level"),
            MyBox(Colors.white, height: 22, text: ""),
          ],
        ),
      ),
    );

    containers.add(
      Container(
        child: Row(
          children: <Widget>[
            ElevatedButton(
              onPressed: () {
                if (CS.Regen_Level > 0) {
                  setState(() {
                    CS.Regen_Level--;
                    UART_characteristic?.write(prepare_Ant_Message(16, CS));
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                backgroundColor: darkBlue,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Icon(Icons.arrow_circle_down_rounded, color: Colors.white),
            ),
            MyBox(mediumBlue, height: 70, fontSize: 48, fontColor: Colors.white, text: CS.Regen_Level.toString()),
            ElevatedButton(
              onPressed: () {
                if (CS.Regen_Level < 7) {
                  setState(() {
                    CS.Regen_Level++;
                    debugPrint('Button Level Up');
                    UART_characteristic?.write(prepare_Ant_Message(16, CS));
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                backgroundColor: darkBlue,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Icon(Icons.arrow_circle_up_rounded, color: Colors.white),
            ),
          ],
        ),
      ),
    );

    containers.add(
      Container(
        child: Row(
          children: <Widget>[
            MyBox(Colors.white, height: 22, text: ""),
            MyBox(Colors.white, height: 22, text: "Assist Level"),
            MyBox(Colors.white, height: 22, text: ""),
          ],
        ),
      ),
    );

    containers.add(
      Container(
        child: Row(
          children: <Widget>[
            ElevatedButton(
              onPressed: () {
                if (CS.Assist_Level > 0) {
                  setState(() {
                    CS.Assist_Level--;
                    UART_characteristic?.write(prepare_Ant_Message(16, CS));
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                backgroundColor: darkBlue,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Icon(Icons.arrow_circle_down_rounded, color: Colors.white),
            ),
            MyBox(mediumBlue, height: 70, fontSize: 48, fontColor: Colors.white, text: CS.Assist_Level.toString()),
            ElevatedButton(
              onPressed: () {
                if (CS.Assist_Level < 7) {
                  setState(() {
                    CS.Assist_Level++;
                    UART_characteristic?.write(prepare_Ant_Message(16, CS));
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                backgroundColor: darkBlue,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Icon(Icons.arrow_circle_up_rounded, color: Colors.white),
            ),
          ],
        ),
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(4),
      children: <Widget>[
        ...containers,
      ],
    );
  }

  void handleClick(String value) {
    switch (value) {
      case 'Main View':
        setState(() {
          viewNumber = 1;
        });
        break;
      case 'Connect Device':
        setState(() {
          viewNumber = 0;
        });
        break;
      case 'Set Parameters':
        setState(() {
          viewNumber = 3;
        });
        break;
    }
  }

  void initLP() {
    LP.trip = 0;
    LP.deviceName = "EBiCS";
  }

  void initCS() {
    CS.Temperature_State = 0;
    CS.Travel_Mode_State = 0;
    CS.System_State = 0;
    CS.Gear_State = 0;
    CS.LEV_Error = 0;
    CS.Speed = 1;
    CS.Assist_Level = 3;
    CS.Regen_Level = 3;

    //page 2
    CS.Odometer = 0;
    CS.Remaining_range = 0;

    //page 3
    CS.Battery_SOC = 0;
    CS.Percentage_Assist = 0;

    //page 4
    CS.Charging_Cycle = 0;
    CS.Fuel_Consumption = 0;
    CS.Battery_Voltage = 0;
    CS.Distance_On_Recent_Charge = 0;

    //page 5
    CS.Travel_Modes_Supported = 0;
    CS.Wheel_Circumference = 0;

    //page 16
    CS.Display_Command = 0;
    CS.Manufacturer_ID = 0;
  }

  ListView _WelcomeScreen() {
    List<Container> containers = [];
    containers.add(
      Container(
        child: Row(
          children: <Widget>[
            MyBox(mediumBlue, height: 200, text: "Welcome! \r\nWaiting for connection..."),
          ],
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(2),
      children: <Widget>[
        ...containers,
      ],
    );
  }

  ListView _paramSetting() {
    List<Container> containers = [];
    widget.mapJSON.forEach((key, value) {
      containers.add(
        Container(
          height: 25,
          padding: const EdgeInsets.all(3.0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text('$key'),
                    Text('$value'),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18.0),
                          side: const BorderSide(color: Colors.red),
                        ),
                      ),
                      child: const Text('Set'),
                      onPressed: () async {
                        _writeController.text = '$value';
                        await showDialog(
                          context: context,
                          builder: (BuildContext context) {
                            return AlertDialog(
                              title: const Text("Set parameter"),
                              content: Row(
                                children: <Widget>[
                                  Expanded(
                                    child: TextField(
                                      controller: _writeController,
                                    ),
                                  ),
                                ],
                              ),
                              actions: <Widget>[
                                TextButton(
                                  child: const Text("Set"),
                                  onPressed: () {
                                    setState(() {
                                      if (int.tryParse(_writeController.value.text) != null) {
                                        widget.mapJSON[key] = int.parse(_writeController.value.text);
                                      } else {
                                        widget.mapJSON[key] = _writeController.value.text;
                                      }
                                    });
                                    jsonFile.writeAsStringSync(json.encode(widget.mapJSON));
                                    assignJSON_CS(widget.mapJSON, CS);
                                    assignJSON_LP(widget.mapJSON, LP);
                                    Navigator.pop(context);
                                    debugPrint('mapJSON: $key ${widget.mapJSON[key]}');
                                  },
                                ),
                                TextButton(
                                  child: const Text("Cancel"),
                                  onPressed: () {
                                    Navigator.pop(context);
                                  },
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
    containers.add(
      Container(
        height: 50,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            TextButton(
              style: TextButton.styleFrom(backgroundColor: Colors.blue),
              child: const Text('Run autodetect routine', style: TextStyle(color: Colors.white)),
              onPressed: () {
                CS.autoDetect = 1;
                UART_characteristic?.write(prepare_Ant_Message(6, CS));
                CS.autoDetect = 0;
              },
            ),
          ],
        ),
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(8),
      children: <Widget>[
        ...containers,
      ],
    );
  }

  Widget _buildView() {
    switch (viewNumber) {
      case 0:
        return _buildListViewOfDevices();
      case 1:
        return _buildConnectDeviceView();
      case 3:
        return _paramSetting();
      case 2:
      default:
        return _WelcomeScreen();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(
            widget.title,
            textAlign: TextAlign.center,
          ),
          leading: IconButton(
            icon: Image.asset('assets/EBiCS_Icon.png'),
            onPressed: () {},
          ),
          actions: <Widget>[
            IconButton(
              icon: Icon(Icons.bluetooth_connected_rounded, color: BT_color),
              onPressed: () {},
            ),
            IconButton(
              icon: Icon(Icons.radio_button_on, color: OnOff_color),
              onPressed: () {
                OnOff = !OnOff; //toggle
                if (OnOff) {
                  setState(() {
                    UART_characteristic?.write(utf8.encode('AT+PIO21'));
                    OnOff_color = Colors.green[900]!;
                  });
                } else {
                  setState(() {
                    UART_characteristic?.write(utf8.encode('AT+PIO20'));
                    OnOff_color = Colors.grey;
                  });
                }
              },
            ),
            PopupMenuButton<String>(
              onSelected: handleClick,
              itemBuilder: (BuildContext context) {
                return {'Main View', 'Connect Device', 'Set Parameters'}.map((String choice) {
                  return PopupMenuItem<String>(
                    value: choice,
                    child: Text(choice),
                  );
                }).toList();
              },
            ),
          ],
        ),
        body: _buildView(),
      );
}

const lightBlue = Color(0xff00bbff);
const mediumBlue = Color(0xff00a2fc);
const darkBlue = Color(0xff0075c9);

final lightGreen = Colors.green.shade300;
final mediumGreen = Colors.green.shade600;
final darkGreen = Colors.green.shade900;

final lightRed = Colors.red.shade300;
final mediumRed = Colors.red.shade600;
final darkRed = Colors.red.shade900;

class MyBox extends StatelessWidget {
  final Color color;
  final double? height;
  final Color? fontColor;
  final double? fontSize;
  final String? text;

  const MyBox(this.color, {super.key, this.height, this.fontSize, this.fontColor, this.text});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(5),
        color: color,
        height: height ?? 150,
        child: text == null
            ? null
            : Center(
                child: Text(
                  text!,
                  style: TextStyle(
                    fontSize: fontSize ?? 18,
                    color: fontColor ?? Colors.black,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
      ),
    );
  }
}

class MyGauge extends StatelessWidget {
  final double zeigerwert;

  const MyGauge(this.zeigerwert, {super.key});

  @override
  Widget build(BuildContext context) {
    return _getMarkerPointerExample(zeigerwert);
  }

  // Returns the marker pointer gauge
  SfRadialGauge _getMarkerPointerExample(double paramvalue) {
    return SfRadialGauge(
      enableLoadingAnimation: true,
      axes: <RadialAxis>[
        RadialAxis(
          interval: 5,
          maximum: 60,
          axisLineStyle: const AxisLineStyle(
            thickness: 0.05,
            thicknessUnit: GaugeSizeUnit.factor,
          ),
          showTicks: true,
          axisLabelStyle: const GaugeTextStyle(
            fontSize: 18,
          ),
          labelOffset: 25,
          radiusFactor: 0.95,
          pointers: <GaugePointer>[
            NeedlePointer(
              needleLength: 0.7,
              value: paramvalue,
              lengthUnit: GaugeSizeUnit.factor,
              needleColor: _needleColor,
              needleStartWidth: 0,
              needleEndWidth: 4,
              knobStyle: KnobStyle(
                sizeUnit: GaugeSizeUnit.factor,
                color: _needleColor,
                knobRadius: 0.05,
              ),
            ),
          ],
          annotations: <GaugeAnnotation>[
            GaugeAnnotation(
              angle: 270,
              positionFactor: 0.5,
              widget: const Text(
                'km/h',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ],
    );
  }

  final Color _needleColor = const Color(0xFFC06C84);
}
