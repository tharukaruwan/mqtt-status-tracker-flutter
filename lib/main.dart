import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key}); // Added const constructor
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  MqttServerClient? _client;
  Timer? _statusTimer;
  final String _broker = '172.235.63.132';
  final int _port = 1884; // Changed back to 1883, verify your broker's port
  final String _userId =
      'user123'; // This seems to be a fixed user ID for topics
  late String _clientId; // This is the unique client instance ID
  String _connectionStatus = 'Initializing...';
  bool _wasOnline =
      false; // Tracks if client was previously connected and online
  bool _isConnecting =
      false; // Flag to prevent multiple simultaneous connection attempts
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  // Debounce timers to prevent rapid state flipping / excessive publishing
  Timer? _reconnectDebounceTimer;
  Timer? _publishStatusDebounceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clientId = 'client_${DateTime.now().millisecondsSinceEpoch}';
    _monitorConnectivity(); // Start monitoring connectivity first
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _reconnectDebounceTimer?.cancel();
    _publishStatusDebounceTimer?.cancel();
    _connectivitySub?.cancel();
    _performCleanDisconnect(); // Call the unified clean disconnect logic
    super.dispose();
  }

  // Unified method to handle clean disconnection and sending offline status
  void _performCleanDisconnect() {
    if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
      print('Performing clean disconnect: Publishing offline status.');
      _publishStatus('offline (clean)'); // Explicitly send offline status
    }
    if (_client != null) {
      try {
        _client!.disconnect();
        print('MQTT client disconnected.');
      } catch (e) {
        print('Error during client disconnect: $e');
      }
      _client = null;
    }
    _wasOnline = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('App Lifecycle changed: $state');
    if (state == AppLifecycleState.paused) {
      // App going to background
      if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
        print('App paused: stopping heartbeat and publishing paused status.');
        _statusTimer?.cancel(); // Stop heartbeat to save resources
        _publishStatus('paused'); // Inform broker that app is paused
      }
    } else if (state == AppLifecycleState.resumed) {
      // App coming to foreground
      print('App resumed: checking connectivity and reconnecting if needed.');
      // Re-evaluate connectivity and connection state
      _monitorConnectivity(forceCheck: true); // Force an immediate check
    }
  }

  // Monitors network connectivity changes
  void _monitorConnectivity({bool forceCheck = false}) async {
    if (_connectivitySub == null || forceCheck) {
      if (_connectivitySub != null) {
        await _connectivitySub!
            .cancel(); // Cancel existing subscription if forcing
      }
      // Initial check
      final List<ConnectivityResult> initialResult =
          await Connectivity().checkConnectivity();
      _handleConnectivityResult(initialResult);

      // Listen for future changes
      _connectivitySub = Connectivity().onConnectivityChanged.listen((
        List<ConnectivityResult> result,
      ) {
        _handleConnectivityResult(result);
      });
    }
  }

  void _handleConnectivityResult(List<ConnectivityResult> results) {
    final bool hasInternet = !results.contains(ConnectivityResult.none);
    print('Connectivity results: $results. Has internet: $hasInternet');

    if (!hasInternet) {
      setState(() => _connectionStatus = 'No Internet');
      print('Network lost. Disconnecting MQTT client if connected.');
      _statusTimer?.cancel(); // Stop heartbeat
      // Only publish offline if we were actually online and lost internet.
      // The LWT is for broker-side, this is for proactive client-side notification.
      if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
        _publishStatus('offline (no internet)');
      }
      _client?.disconnect(); // Force disconnect
      _wasOnline = false; // Mark as not online
    } else {
      setState(() => _connectionStatus = 'Internet Available');
      // If internet is back and we are not connected, or were disconnected, try to connect
      if (!_isConnecting &&
          (_client == null ||
              _client!.connectionStatus?.state !=
                  MqttConnectionState.connected)) {
        _scheduleReconnect();
      } else if (_client?.connectionStatus?.state ==
          MqttConnectionState.connected) {
        // If already connected, ensure heartbeat is running and send online status
        _startStatusUpdates();
        _publishStatus('online (network restored)');
      }
    }
  }

  void _connectMqtt() async {
    if (_isConnecting) {
      print('Connection already in progress. Skipping new attempt.');
      return;
    }
    // Only attempt if there's internet connectivity
    final List<ConnectivityResult> currentConnectivity =
        await Connectivity().checkConnectivity();
    if (currentConnectivity.contains(ConnectivityResult.none)) {
      print('Cannot connect: No internet connection.');
      setState(() => _connectionStatus = 'No Internet');
      return;
    }

    _isConnecting = true;
    _performCleanDisconnect(); // Ensure previous client is properly disconnected
    setState(() => _connectionStatus = 'Connecting...');
    print('⚡ Attempting to connect to MQTT broker...');

    // LWT payload for unexpected disconnections
    final offlineWillPayload = jsonEncode({
      'status': 'offline (LWT)',
      'geo': {
        'lat': '6.9271',
        'lon': '79.8612',
      }, // Current geo-location for LWT
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });

    _client = MqttServerClient.withPort(_broker, _clientId, _port);
    _client!.logging(on: true); // Enable detailed logging
    _client!.keepAlivePeriod = 20; // Keep alive 20 seconds
    _client!.autoReconnect =
        true; // Client will attempt to reconnect automatically
    _client!.resubscribeOnAutoReconnect =
        true; // Resubscribe topics on auto-reconnect
    _client!.onConnected = _onConnected;
    _client!.onDisconnected = _onDisconnected;
    // Corrected: Assign callbacks directly, no chaining after print()
    _client!.onAutoReconnect = () => print('🔄 MQTT auto reconnecting...');
    _client!.onAutoReconnected = () => print('✅ MQTT auto reconnected');
    _client!.onSubscribed = (topic) => print('📡 Subscribed to $topic');
    _client!.onSubscribeFail = (topic) => print('❌ Failed to subscribe $topic');
    _client!.pongCallback = () => print('🏓 Ping response received');

    // Configure connection message including LWT
    _client!.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .startClean() // Clean session to ensure new state
        .withWillTopic('status/$_clientId') // LWT topic using unique client ID
        .withWillMessage(offlineWillPayload)
        .withWillQos(MqttQos.atLeastOnce);

    try {
      await _client!.connect();
    } catch (e) {
      print('❌ MQTT connection failed: $e');
      _performCleanDisconnect(); // Handle error by ensuring client is disconnected
      setState(() => _connectionStatus = 'Connection Failed: $e');
    } finally {
      _isConnecting = false;
    }
  }

  void _scheduleReconnect() {
    if (_reconnectDebounceTimer?.isActive ?? false) return;
    print('Scheduling reconnect in 3 seconds...');
    _reconnectDebounceTimer = Timer(const Duration(seconds: 3), () {
      print('Scheduled reconnect triggered. Attempting connection...');
      _connectMqtt();
    });
  }

  void _onConnected() {
    print('✅ Connected to MQTT broker');
    setState(() => _connectionStatus = 'Connected');
    _startStatusUpdates(); // Start periodic heartbeats
    _publishStatus('online (initial)'); // Publish initial online status
    _wasOnline = true; // Mark that we are now online
  }

  void _onDisconnected() {
    print('🔌 Disconnected from MQTT broker');
    setState(() => _connectionStatus = 'Disconnected');
    _statusTimer?.cancel(); // Stop heartbeats
    // LWT will handle the "offline" message for unclean disconnects.
    // If it was a clean disconnect (e.g., app dispose), _performCleanDisconnect handled it.
    _wasOnline = false; // Mark as not online
    // Attempt reconnect if not a clean disconnect and auto-reconnect is not handling it
    if (!_isConnecting &&
        _client?.connectionStatus?.state != MqttConnectionState.connected) {
      _scheduleReconnect();
    }
  }

  // Starts the timer for periodic online status updates (heartbeat)
  void _startStatusUpdates() {
    _statusTimer?.cancel(); // Cancel any existing timer
    _statusTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
        // TODO: Implement actual geo-location retrieval here using geolocator
        // try {
        //   Position position = await Geolocator.getCurrentPosition(
        //     desiredAccuracy: LocationAccuracy.low,
        //     timeLimit: const Duration(seconds: 5)
        //   );
        //   _currentGeoLocation = {
        //     'lat': position.latitude.toString(),
        //     'lon': position.longitude.toString(),
        //   };
        // } catch (e) {
        //   print('Failed to get updated geo-location: $e');
        // }
        _publishStatus('online (heartbeat)');
      } else {
        print('MQTT not connected for heartbeat. Stopping status updates.');
        _statusTimer?.cancel();
      }
    });
    print('Started periodic status updates (every 10s).');
  }

  // Publishes status messages with a debounce to prevent rapid spamming
  void _publishStatus(String status) {
    _publishStatusDebounceTimer?.cancel(); // Cancel any pending debounce
    _publishStatusDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _sendMqttStatus(status);
    });
  }

  // Internal function to send the MQTT status message
  void _sendMqttStatus(String status) {
    if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
      // Use _clientId for the unique client's status topic
      final topic = 'status/$_clientId';
      final payload = jsonEncode({
        'status': status,
        'geo': {
          "lat": "6.9271",
          "lon": "79.8612",
        }, // _currentGeoLocation, // Include current geo-location
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });

      final builder = MqttClientPayloadBuilder()..addString(payload);
      _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
      print('📤 Published "$status" to $topic');

      // Update _wasOnline flag based on the published status
      _wasOnline = status.toLowerCase().startsWith('online');
    } else {
      print('⚠️ Cannot publish "$status" status: MQTT not connected.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('MQTT Auto Status Tracker')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _connectionStatus.contains('Connected')
                    ? Icons.cloud_done
                    : (_connectionStatus.contains('Connecting') || _isConnecting
                        ? Icons.cloud_upload
                        : Icons.cloud_off),
                color:
                    _connectionStatus.contains('Connected')
                        ? Colors.green
                        : (_connectionStatus.contains('Connecting') ||
                                _isConnecting
                            ? Colors.orange
                            : Colors.red),
                size: 60,
              ),
              const SizedBox(height: 20),
              Text(
                'MQTT Status: $_connectionStatus',
                style: const TextStyle(fontSize: 24),
              ),
              Text(
                'Client ID: $_clientId',
                style: const TextStyle(fontSize: 14, color: Colors.grey),
              ),
              Text(
                'Broker: $_broker:$_port',
                style: const TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 20),
              // Manual reconnect button if disconnected or error
              if (_connectionStatus.contains('Disconnected') ||
                  _connectionStatus.contains('No Internet') ||
                  _connectionStatus.contains('Failed'))
                ElevatedButton(
                  onPressed: _isConnecting ? null : _connectMqtt,
                  child:
                      _isConnecting
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text('Retry Connection'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
