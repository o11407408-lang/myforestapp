import 'package:flutter/material.dart';
import 'dart:async';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'фокус дерево',
      theme: ThemeData(
        primarySwatch: Colors.green,
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const FocusScreen(),
    );
  }
}

class FocusScreen extends StatefulWidget {
  const FocusScreen({Key? key}) : super(key: key);

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> with WidgetsBindingObserver {
  bool _isFocusing = false;
  int _secondsRemaining = 300;
  Timer? _timer;
  String _statusText = 'выберите дерево и начните сеанс';
  double _treeGrowth = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_isFocusing && (state == AppLifecycleState.paused || state == AppLifecycleState.inactive)) {
      _killTree();
    }
  }

  void _startFocus() {
    setState(() {
      _isFocusing = true;
      _secondsRemaining = 300;
      _treeGrowth = 0.0;
      _statusText = '';
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_secondsRemaining > 0) {
          _secondsRemaining--;
          _treeGrowth = (300 - _secondsRemaining) / 300;
        } else {
          _finishFocus();
        }
      });
    });
  }

  void _killTree() {
    _timer?.cancel();
    setState(() {
      _isFocusing = false;
      _statusText = 'вы покинули приложение! дерево погибло 🥀';
    });
  }

  void _finishFocus() {
    _timer?.cancel();
    setState(() {
      _isFocusing = false;
      _statusText = 'поздравляем! дерево успешно выросло 🌳';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFE8F5E9), Colors.white],
            stops: [0.0, 0.3],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'марат',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.bar_chart, color: Colors.black54),
                          onPressed: () {},
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings_outlined, color: Colors.black54),
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.03),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(30),
                          decoration: const BoxDecoration(
                            color: Color(0xFFE8F5E9),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _isFocusing
                                ? (_treeGrowth < 0.5 ? Icons.eco : Icons.park)
                                : (_statusText.contains('погибло') ? Icons.park_outlined : Icons.spa),
                            size: 80,
                            color: _statusText.contains('погибло') ? Colors.green.shade900 : const Color(0xFF4CAF50),
                          ),
                        ),
                        const SizedBox(height: 30),
                        Text(
                          _isFocusing
                              ? '${_secondsRemaining ~/ 60}:${(_secondsRemaining % 60).toString().padLeft(2, '0')}'
                              : (_statusText.isEmpty ? 'время фокуса: 5 мин' : _statusText),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: _statusText.contains('погибло') ? Colors.green.shade800 : Colors.black87,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (_isFocusing) ...[
                          const SizedBox(height: 15),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 40),
                            child: LinearProgressIndicator(
                              value: _treeGrowth,
                              backgroundColor: const Color(0xFFE8F5E9),
                              color: const Color(0xFF4CAF50),
                              minHeight: 8,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'не выходите из приложения, иначе дерево умрет!',
                            style: TextStyle(fontSize: 12, color: Color(0xFF66BB6A)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (!_isFocusing)
                  SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      onPressed: _startFocus,
                      child: const Text(
                        'посадить дерево',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
