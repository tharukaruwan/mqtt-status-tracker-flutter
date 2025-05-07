import 'dart:async';
import 'dart:convert';
import 'dart:io'; // Import for Platform checks if needed later, or for SocketException

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart'; // Updated import for connectivity_plus API change
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
// import 'package:mqtt_client/mqtt_browser_client.dart'; // Use this for web

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MQTT Status & CMD Tracker',
      theme: ThemeData(
        // Added some basic theme for better look
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: StatusScreen(),
    );
  }
}

class StatusScreen extends StatefulWidget {
  @override
  _StatusScreenState createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen>
    with WidgetsBindingObserver {
  // ─────────────────────────
  // ■ Configuration
  // ─────────────────────────
  // !!! IMPORTANT: Verify the Broker IP and Port are correct and accessible !!!
  // This IP (172.235.63.132) looks like a public IP range, ensure it's your broker's public IP.
  // Ensure your broker is running and accessible from where you run the app.
  static const _broker = '172.235.63.132'; // Verify this IP address
  static const _port = 1883; // Verify this port

  // !!! IMPORTANT: Verify these topics match exactly with your MQTT setup !!!
  static const _cmdTopic =
      'storagelocation/67bd669d69149157396e7e74/'
      'salesmen/6810c7608f1e11a76ca5ab68/cmd'; // Topic to receive commands
  static const _statusTopic =
      'storagelocation/67bd669d69149157396e7e74/'
      'salesmen/6810c7608f1e11a76ca5ab68/status'; // Topic to send status

  // Generate a unique client ID
  final String _clientId = 'flutter_${DateTime.now().millisecondsSinceEpoch}';

  // ─────────────────────────
  // ■ MQTT + Connectivity
  // ─────────────────────────
  MqttServerClient? _client; // Use MqttBrowserClient for web
  StreamSubscription<List<ConnectivityResult>>?
  _connectivitySub; // Updated type for connectivity_plus >= 3.0.0
  Timer? _heartbeatTimer;
  bool _isConnecting =
      false; // Added state to prevent multiple connection attempts

  // ─────────────────────────
  // ■ UI State
  // ─────────────────────────
  String _connectionState = 'Initializing...'; // Initial state
  final List<String> _cmdMessages = [];

  @override
  void initState() {
    super.initState();
    _initConnectivityWatcher();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _stopHeartbeat();
    _client?.disconnect();
    super.dispose();
  }

  // ─────────────────────────
  // ■ App Lifecycle (optional send offline on background)
  // ─────────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('App Lifecycle State Changed: $state');
    if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
      if (state == AppLifecycleState.paused) {
        // App is going to the background
        _publishStatus('offline (paused)');
      } else if (state == AppLifecycleState.resumed) {
        // App is coming to the foreground
        _publishStatus('online (resumed)');
      }
      // Note: AppLifecycleState.inactive and .detached might also occur.
      // 'paused' is the most common state when user switches apps.
    } else {
      print(
        'App lifecycle change: Client not connected. Cannot publish status.',
      );
      // If app resumes and client is not connected, maybe attempt reconnect?
      // Only attempt reconnect if we are not already connecting or connected
      if (state == AppLifecycleState.resumed &&
          !_isConnecting &&
          (_client == null ||
              _client?.connectionStatus?.state ==
                  MqttConnectionState.disconnected)) {
        print('App resumed and client not connected. Attempting reconnect.');
        _connectAndListen(); // Try to reconnect on resume if disconnected
      }
    }
  }

  // ─────────────────────────
  // ■ Connectivity Watcher
  // ─────────────────────────
  void _initConnectivityWatcher() {
    print('Initializing Connectivity Watcher');
    Connectivity().checkConnectivity().then((result) {
      _handleConnectivityResult(result); // Check initial state
    });

    _connectivitySub = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results, // Updated parameter type
    ) {
      _handleConnectivityResult(results); // Handle changes
    });
  }

  void _handleConnectivityResult(List<ConnectivityResult> results) {
    // Updated parameter type
    print('Connectivity changed: $results');
    // Check if any of the results indicate no internet
    final isNone = results.contains(ConnectivityResult.none);

    if (isNone) {
      setState(() => _connectionState = 'No Internet');
      // Attempt to send status if still connected, useful if internet drops
      // but the MQTT client hasn't realized it yet (until keep-alive fails)
      _publishStatus('offline (no internet)');
      // No need to explicitly disconnect client here, autoReconnect should handle it
    } else {
      setState(() => _connectionState = 'Internet Available');
      // If connectivity is restored and client is disconnected, try to connect
      if (!_isConnecting &&
          (_client == null ||
              _client?.connectionStatus?.state ==
                  MqttConnectionState.disconnected)) {
        print(
          'Connectivity restored and client is disconnected. Attempting reconnect.',
        );
        _connectAndListen();
      } else {
        // If already connected or connecting, and internet is available
        // We could publish 'online' here, but heartbeat or onConnected already do this.
        // Avoid excessive publishing.
      }
    }
  }

  // ─────────────────────────
  // ■ MQTT Connect & Subscribe
  // ─────────────────────────
  Future<void> _connectAndListen() async {
    if (_client?.connectionStatus?.state == MqttConnectionState.connected)
      return;

    _client =
        MqttServerClient.withPort(_broker, _clientId, _port)
          ..logging(on: true)
          ..keepAlivePeriod =
              5 // <<—— very short keep-alive
          ..autoReconnect = true
          ..onConnected = _onConnected
          ..onDisconnected = _onDisconnected
          ..connectionMessage =
              MqttConnectMessage()
                  .withWillTopic(_statusTopic)
                  .withWillMessage('offline (LWT)')
                  .withWillQos(MqttQos.atLeastOnce)
                  .startClean();

    try {
      await _client!.connect();
    } catch (_) {
      _client?.disconnect();
    }
  }

  void _onConnected() {
    setState(() => _connectionState = 'MQTT Connected');
    _publishStatus('online'); // immediately announce you're back
    _client!.subscribe(_cmdTopic, MqttQos.atLeastOnce);
    _client!.updates!.listen(_onMessage);
    _startHeartbeat();
  }

  void _onDisconnected() {
    print('MQTT disconnected (app-side)');
    _stopHeartbeat();
    // NOTE: Do not try to publish here — connection is gone.
    setState(() => _connectionState = 'MQTT Disconnected');
    // broker will publish LWT "offline (LWT)" after ~5s
  }

  // Handle incoming messages
  void _onMessage(List<MqttReceivedMessage<MqttMessage?>>? events) {
    // --- FIX: Add safety check for null or empty events list ---
    if (events == null || events.isEmpty) {
      print('Received null or empty MQTT message list. Ignoring.');
      return;
    }

    // Loop through all messages in the list (although often it's just one)
    for (final messageEvent in events) {
      final MqttMessage? message = messageEvent.payload;

      // --- FIX: Check if payload is valid MqttPublishMessage ---
      if (message is! MqttPublishMessage) {
        print(
          'Received non-publish message type: ${message?.runtimeType}. Ignoring.',
        );
        continue; // Skip to the next message if not a publish message
      }

      final MqttPublishMessage rec = message;
      final String topic = messageEvent.topic ?? 'Unknown Topic'; // Get topic
      final msg = MqttPublishPayload.bytesToStringAsString(rec.payload.message);
      print('CMD received on topic "$topic": "$msg"');

      // parse JSON or raw
      String display = msg;
      try {
        final jsonObj = json.decode(msg);
        if (jsonObj is Map) {
          // Check for common command keys or just display the map
          if (jsonObj.containsKey('command') && jsonObj['command'] is String) {
            display = 'CMD ▶ ${jsonObj['command']}';
          } else {
            display =
                'JSON Map ▶ ${jsonObj.toString()}'; // Display the map content
          }
        } else if (jsonObj is List) {
          display = 'JSON List ▶ ${jsonObj.toString()}'; // Display list content
        } else {
          display =
              'JSON Value ▶ ${jsonObj.toString()}'; // Display other JSON primitives
        }
      } catch (e) {
        // If JSON parsing fails, display the raw message
        // print('Failed to parse message as JSON: $e'); // Keep this print for debugging specific messages
        display = 'RAW ▶ $msg';
      }

      // Update UI state with the received command message
      // Use insert(0) to add to the beginning of the list
      setState(
        () => _cmdMessages.insert(
          0,
          '[${DateTime.now().toLocal().toString().substring(11, 19)}] $display',
        ), // Added timestamp formatting
      );
    }
  }

  // ─────────────────────────
  // ■ Periodic Heartbeat
  // ─────────────────────────
  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(Duration(seconds: 30), (_) {
      if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
        _publishStatus('online (heartbeat)');
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _publishStatus(String status) {
    if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
      final builder = MqttClientPayloadBuilder()..addString(status);
      _client!.publishMessage(
        _statusTopic,
        MqttQos.atLeastOnce,
        builder.payload!,
        retain: false,
      );
      print('Published status: $status');
    }
  }

  // ─────────────────────────
  // ■ Build UI
  // ─────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('MQTT Status & CMD Tracker')),
      body: Column(
        crossAxisAlignment:
            CrossAxisAlignment.stretch, // Stretch children horizontally
        children: [
          ListTile(
            leading: Icon(
              _connectionState.contains('Connected')
                  ? Icons
                      .cloud_done // Connected icon
                  : (_connectionState.contains('Connecting')
                      ? Icons.cloud_upload
                      : Icons.cloud_off), // Connecting or Disconnected icon
              color:
                  _connectionState.contains('Connected')
                      ? Colors
                          .green // Connected color
                      : (_connectionState.contains('Connecting')
                          ? Colors.orange
                          : Colors.red), // Connecting or Disconnected color
            ),
            title: Text('Connection: $_connectionState'),
            trailing:
                _connectionState.contains('Disconnected') ||
                        _connectionState.contains('Failed') ||
                        _connectionState.contains('Exception')
                    ? IconButton(
                      // Add a retry button if disconnected or failed
                      icon: Icon(Icons.refresh),
                      onPressed:
                          _isConnecting
                              ? null
                              : _connectAndListen, // Disable while connecting
                      tooltip: 'Retry Connection',
                    )
                    : null, // No trailing button if connected
          ),
          Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Text(
              'Received Commands:',
              // FIX: Use headlineSmall instead of deprecated headline6
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: ListView.builder(
              reverse:
                  false, // Keep reverse: false as insert(0) adds to the top
              padding: EdgeInsets.all(12),
              itemCount: _cmdMessages.length,
              itemBuilder:
                  (_, i) => Card(
                    margin: EdgeInsets.symmetric(vertical: 4),
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: Text(
                        _cmdMessages[i],
                        style: TextStyle(fontSize: 14.0),
                      ),
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
