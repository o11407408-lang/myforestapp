import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  final appState = AppState();
  await appState.load();
  runApp(MyApp(appState: appState));
}

// ---------------------------------------------------------------------------
// Виды деревьев
// ---------------------------------------------------------------------------

class TreeSpecies {
  final String id;
  final String name;
  final IconData icon;
  final Color color;
  final int unlockAt; // сколько успешных деревьев нужно вырастить, 0 = открыт сразу

  const TreeSpecies({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    required this.unlockAt,
  });
}

const List<TreeSpecies> treeSpecies = [
  TreeSpecies(
    id: 'oak',
    name: 'Дуб',
    icon: Icons.park_rounded,
    color: Color(0xFF2E7D32),
    unlockAt: 0,
  ),
  TreeSpecies(
    id: 'pine',
    name: 'Сосна',
    icon: Icons.forest_rounded,
    color: Color(0xFF1B5E20),
    unlockAt: 3,
  ),
  TreeSpecies(
    id: 'sakura',
    name: 'Сакура',
    icon: Icons.local_florist_rounded,
    color: Color(0xFFEC407A),
    unlockAt: 7,
  ),
  TreeSpecies(
    id: 'palm',
    name: 'Пальма',
    icon: Icons.beach_access_rounded,
    color: Color(0xFF00897B),
    unlockAt: 12,
  ),
  TreeSpecies(
    id: 'maple',
    name: 'Клён',
    icon: Icons.eco_rounded,
    color: Color(0xFFE65100),
    unlockAt: 20,
  ),
  TreeSpecies(
    id: 'gold',
    name: 'Золотое дерево',
    icon: Icons.auto_awesome_rounded,
    color: Color(0xFFFFB300),
    unlockAt: 30,
  ),
];

TreeSpecies speciesById(String id) {
  return treeSpecies.firstWhere(
    (s) => s.id == id,
    orElse: () => treeSpecies.first,
  );
}

/// Переводит первую букву строки в нижний регистр — используется, когда имя
/// вида дерева подставляется в середину предложения (а не в его начало).
String lower1(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

// ---------------------------------------------------------------------------
// Модель данных сеанса
// ---------------------------------------------------------------------------

class FocusSession {
  final DateTime date;
  final int durationMinutes;
  final bool success;
  final String speciesId;

  FocusSession({
    required this.date,
    required this.durationMinutes,
    required this.success,
    required this.speciesId,
  });

  String encode() =>
      '${date.toIso8601String()}|$durationMinutes|${success ? 1 : 0}|$speciesId';

  static FocusSession? decode(String raw) {
    final parts = raw.split('|');
    if (parts.length != 4) return null;
    try {
      return FocusSession(
        date: DateTime.parse(parts[0]),
        durationMinutes: int.parse(parts[1]),
        success: parts[2] == '1',
        speciesId: parts[3],
      );
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Сервис уведомлений
// ---------------------------------------------------------------------------

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const _dailyChannelId = 'focus_tree_daily';
  static const _testChannelId = 'focus_tree_test';

  static Future<void> init() async {
    if (_initialized) return;
    try {
      tzdata.initializeTimeZones();

      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);
      await _plugin.initialize(settings);

      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();

      _initialized = true;
    } catch (e) {
      // Если что-то пошло не так (например, старое устройство или нет
      // прав) — приложение всё равно должно нормально запуститься.
      debugPrint('NotificationService init error: $e');
    }
  }

  static Future<bool> areNotificationsAllowed() async {
    try {
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final enabled = await androidImpl?.areNotificationsEnabled();
      return enabled ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> showTestNotification() async {
    const androidDetails = AndroidNotificationDetails(
      _testChannelId,
      'Тестовые уведомления',
      channelDescription: 'Проверка того, что уведомления реально доставляются',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(0, 'Grove', 'Уведомления работают!', details);
  }

  // Не используем часовые пояса устройства напрямую (их не всегда можно
  // корректно определить без нативного плагина) — вместо этого переводим
  // нужное локальное время в UTC самостоятельно и планируем по UTC.
  static Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
  }) async {
    await cancelDailyReminder();

    const androidDetails = AndroidNotificationDetails(
      _dailyChannelId,
      'Ежедневные напоминания',
      channelDescription: 'Напоминание посадить дерево и сосредоточиться',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    final now = DateTime.now();
    var nextLocal = DateTime(now.year, now.month, now.day, hour, minute);
    if (nextLocal.isBefore(now)) {
      nextLocal = nextLocal.add(const Duration(days: 1));
    }
    final scheduled = tz.TZDateTime.from(nextLocal.toUtc(), tz.UTC);

    try {
      await _plugin.zonedSchedule(
        1,
        'Пора сосредоточиться',
        'Посадите дерево и не отвлекайтесь',
        scheduled,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (e) {
      // На части устройств (особенно Android 12+ без разрешения на точные
      // будильники) точная доставка недоступна — используем неточный режим,
      // это лучше, чем совсем без напоминаний.
      debugPrint('exact schedule failed, falling back to inexact: $e');
      try {
        await _plugin.zonedSchedule(
          1,
          'Пора сосредоточиться',
          'Посадите дерево и не отвлекайтесь',
          scheduled,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time,
        );
      } catch (e2) {
        debugPrint('inexact schedule also failed: $e2');
      }
    }
  }

  static Future<void> cancelDailyReminder() async {
    await _plugin.cancel(1);
  }
}

// ---------------------------------------------------------------------------
// Состояние приложения
// ---------------------------------------------------------------------------

String _capitalize(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return trimmed;
  return trimmed[0].toUpperCase() + trimmed.substring(1);
}

class AppState extends ChangeNotifier {
  String userName = '';
  String lastName = '';
  int selectedDuration = 15;
  String selectedSpeciesId = 'oak';

  bool notificationsEnabled = true;
  bool soundEnabled = true;
  bool vibrationEnabled = true;
  int reminderHour = 20;
  int reminderMinute = 0;
  int themeIndex = 0;

  final List<FocusSession> history = [];

  static const _kUserName = 'userName';
  static const _kLastName = 'lastName';
  static const _kSelectedDuration = 'selectedDuration';
  static const _kSelectedSpeciesId = 'selectedSpeciesId';
  static const _kNotificationsEnabled = 'notificationsEnabled';
  static const _kSoundEnabled = 'soundEnabled';
  static const _kVibrationEnabled = 'vibrationEnabled';
  static const _kReminderHour = 'reminderHour';
  static const _kReminderMinute = 'reminderMinute';
  static const _kThemeIndex = 'themeIndex';
  static const _kHistory = 'history';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    userName = prefs.getString(_kUserName) ?? '';
    lastName = prefs.getString(_kLastName) ?? '';
    selectedDuration = prefs.getInt(_kSelectedDuration) ?? 15;
    selectedSpeciesId = prefs.getString(_kSelectedSpeciesId) ?? 'oak';
    notificationsEnabled = prefs.getBool(_kNotificationsEnabled) ?? true;
    soundEnabled = prefs.getBool(_kSoundEnabled) ?? true;
    vibrationEnabled = prefs.getBool(_kVibrationEnabled) ?? true;
    reminderHour = prefs.getInt(_kReminderHour) ?? 20;
    reminderMinute = prefs.getInt(_kReminderMinute) ?? 0;
    themeIndex = prefs.getInt(_kThemeIndex) ?? 0;

    history.clear();
    final rawHistory = prefs.getStringList(_kHistory) ?? [];
    for (final raw in rawHistory) {
      final session = FocusSession.decode(raw);
      if (session != null) history.add(session);
    }

    if (userName.isNotEmpty && notificationsEnabled) {
      await NotificationService.scheduleDailyReminder(
        hour: reminderHour,
        minute: reminderMinute,
      );
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserName, userName);
    await prefs.setString(_kLastName, lastName);
    await prefs.setInt(_kSelectedDuration, selectedDuration);
    await prefs.setString(_kSelectedSpeciesId, selectedSpeciesId);
    await prefs.setBool(_kNotificationsEnabled, notificationsEnabled);
    await prefs.setBool(_kSoundEnabled, soundEnabled);
    await prefs.setBool(_kVibrationEnabled, vibrationEnabled);
    await prefs.setInt(_kReminderHour, reminderHour);
    await prefs.setInt(_kReminderMinute, reminderMinute);
    await prefs.setInt(_kThemeIndex, themeIndex);
    await prefs.setStringList(
      _kHistory,
      history.map((s) => s.encode()).toList(),
    );
  }

  Future<void> completeRegistration(String name, String surname) async {
    userName = _capitalize(name);
    lastName = _capitalize(surname);
    notifyListeners();
    await _persist();
    if (notificationsEnabled) {
      await NotificationService.scheduleDailyReminder(
        hour: reminderHour,
        minute: reminderMinute,
      );
    }
  }

  void setUserName(String name) {
    userName = _capitalize(name);
    notifyListeners();
    _persist();
  }

  void setLastName(String name) {
    lastName = _capitalize(name);
    notifyListeners();
    _persist();
  }

  void setDuration(int minutes) {
    selectedDuration = minutes;
    notifyListeners();
    _persist();
  }

  void setSpecies(String id) {
    selectedSpeciesId = id;
    notifyListeners();
    _persist();
  }

  Future<void> toggleNotifications(bool value) async {
    notificationsEnabled = value;
    notifyListeners();
    _persist();
    if (value) {
      await NotificationService.scheduleDailyReminder(hour: reminderHour, minute: reminderMinute);
    } else {
      await NotificationService.cancelDailyReminder();
    }
  }

  Future<void> setReminderTime(int hour, int minute) async {
    reminderHour = hour;
    reminderMinute = minute;
    notifyListeners();
    _persist();
    if (notificationsEnabled) {
      await NotificationService.scheduleDailyReminder(hour: hour, minute: minute);
    }
  }

  void toggleSound(bool value) {
    soundEnabled = value;
    notifyListeners();
    _persist();
  }

  void toggleVibration(bool value) {
    vibrationEnabled = value;
    notifyListeners();
    _persist();
  }

  /// Полный сброс: настройки, регистрация и лес. Пользователь возвращается
  /// на экран приветствия.
  Future<void> resetEverything() async {
    userName = '';
    lastName = '';
    selectedDuration = 15;
    selectedSpeciesId = 'oak';
    notificationsEnabled = true;
    soundEnabled = true;
    vibrationEnabled = true;
    reminderHour = 20;
    reminderMinute = 0;
    themeIndex = 0;
    history.clear();
    await NotificationService.cancelDailyReminder();
    notifyListeners();
    await _persist();
  }

  void addSession(FocusSession session) {
    history.insert(0, session);
    notifyListeners();
    _persist();
  }

  bool isSpeciesUnlocked(TreeSpecies species) => successfulSessions >= species.unlockAt;

  int get totalSessions => history.length;

  int get successfulSessions => history.where((s) => s.success).length;

  int get totalFocusMinutes => history
      .where((s) => s.success)
      .fold(0, (sum, s) => sum + s.durationMinutes);

  double get successRate =>
      history.isEmpty ? 0 : successfulSessions / history.length;

  int get currentStreak {
    final now = DateTime.now();
    // Сессии, у которых дата "из будущего" относительно текущего реального
    // времени устройства, в серию не засчитываются. Это отсекает попытку
    // накрутить серию переводом даты на телефоне вперёд: пока часы стоят
    // "в будущем", день засчитывается, но как только настоящее время снова
    // становится реальным (часы возвращают назад), такая запись перестаёт
    // учитываться. Полностью защититься от подмены даты без серверного
    // времени невозможно, но эта проверка закрывает основной сценарий.
    final validSessions = history
        .where((s) => s.success && !s.date.isAfter(now))
        .toList();
    if (validSessions.isEmpty) return 0;

    int dayNumber(DateTime d) => DateTime(d.year, d.month, d.day)
        .difference(DateTime(2000, 1, 1))
        .inDays;

    int streak = 0;
    int? lastDayNum;
    for (final session in validSessions) {
      final dn = dayNumber(session.date);
      if (lastDayNum == null) {
        streak = 1;
        lastDayNum = dn;
      } else if (dn == lastDayNum) {
        continue;
      } else if (lastDayNum - dn == 1) {
        streak++;
        lastDayNum = dn;
      } else {
        break;
      }
    }
    return streak;
  }
}

// ---------------------------------------------------------------------------
// Вспомогательные функции
// ---------------------------------------------------------------------------

String pluralizeRu(int n, String one, String few, String many) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return few;
  return many;
}

String formatMinutes(int totalMinutes) {
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) return '$minutes мин';
  return '$hours ч $minutes мин';
}

IconData growthIcon(double growth, TreeSpecies species) {
  if (growth < 0.2) return Icons.grass_rounded;
  if (growth < 0.45) return Icons.eco_rounded;
  if (growth < 0.75) return Icons.park_outlined;
  return species.icon;
}

String formatTimeOfDay(int hour, int minute) {
  final h = hour.toString().padLeft(2, '0');
  final m = minute.toString().padLeft(2, '0');
  return '$h:$m';
}

Route<T> smoothRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

OverlayEntry? _activeToast;

void showAppSnackBar(
  BuildContext context,
  String message, {
  IconData icon = Icons.check_circle_rounded,
}) {
  _activeToast?.remove();
  _activeToast = null;

  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _AppToast(
      message: message,
      onDismissed: () {
        entry.remove();
        if (_activeToast == entry) _activeToast = null;
      },
    ),
  );
  _activeToast = entry;
  overlay.insert(entry);
}

class _AppToast extends StatefulWidget {
  final String message;
  final VoidCallback onDismissed;
  const _AppToast({required this.message, required this.onDismissed});

  @override
  State<_AppToast> createState() => _AppToastState();
}

class _AppToastState extends State<_AppToast> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _offset;
  late final Animation<double> _opacity;
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 260),
    );
    final curved = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _offset = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(curved);
    _opacity = Tween<double>(begin: 0, end: 1).animate(curved);
    _controller.forward();
    _autoDismissTimer = Timer(const Duration(milliseconds: 2600), _dismiss);
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    _autoDismissTimer?.cancel();
    await _controller.reverse();
    widget.onDismissed();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: SafeArea(
        top: false,
        child: SlideTransition(
          position: _offset,
          child: FadeTransition(
            opacity: _opacity,
            child: Material(
              color: Colors.transparent,
              child: GestureDetector(
                onTap: _dismiss,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Text(
                    widget.message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Красивый диалог подтверждения вместо стандартного AlertDialog — с иконкой
/// и кнопками в одну строку, в стиле остального приложения.
Future<bool> showAppConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  IconData icon = Icons.help_outline_rounded,
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.45),
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: destructive ? scheme.errorContainer : scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: destructive ? scheme.error : scheme.primary),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: scheme.onSurface),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      side: BorderSide(color: scheme.outlineVariant),
                      foregroundColor: scheme.onSurface,
                    ),
                    child: const Text('Отмена'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: destructive ? scheme.error : const Color(0xFF43A047),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(confirmLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return result ?? false;
}

// ---------------------------------------------------------------------------
// Корневой виджет
// ---------------------------------------------------------------------------

class MyApp extends StatefulWidget {
  final AppState appState;
  const MyApp({super.key, required this.appState});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32));

    return ListenableBuilder(
      listenable: widget.appState,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Grove',
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: colorScheme,
            scaffoldBackgroundColor: colorScheme.surface,
            appBarTheme: AppBarTheme(
              backgroundColor: colorScheme.surface,
              foregroundColor: colorScheme.onSurface,
              elevation: 0,
              centerTitle: false,
              titleTextStyle: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF43A047),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          home: widget.appState.userName.isEmpty
              ? RegistrationScreen(appState: widget.appState)
              : HomeScreen(appState: widget.appState),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Экран регистрации
// ---------------------------------------------------------------------------

class RegistrationScreen extends StatefulWidget {
  final AppState appState;
  const RegistrationScreen({super.key, required this.appState});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    // Делаем статус-бар прозрачным и с тёмными иконками (фон экрана светлый),
    // вместо попытки полностью скрыть его — это не даёт чёрной полосы,
    // которая появлялась в immersive-режиме на некоторых устройствах.
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      widget.appState.completeRegistration(
        _nameController.text.trim(),
        _lastNameController.text.trim(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child:
                        Icon(Icons.park_rounded, size: 64, color: scheme.primary),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Grove',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Выращивайте деревья, оставаясь сосредоточенными',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 40),
                Text(
                  'Как вас зовут?',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 20,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Имя',
                    filled: true,
                    fillColor: scheme.surfaceVariant,
                    counterText: '',
                    prefixIcon: const Icon(Icons.person_outline_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Введите имя, чтобы продолжить';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _lastNameController,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 20,
                  decoration: InputDecoration(
                    hintText: 'Фамилия',
                    filled: true,
                    fillColor: scheme.surfaceVariant,
                    counterText: '',
                    prefixIcon: const Icon(Icons.badge_outlined),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _submit,
                  child: const Text('Начать'),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Главный экран
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  final AppState appState;
  const HomeScreen({super.key, required this.appState});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isFocusing = false;
  late int _totalSeconds;
  late int _secondsRemaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _totalSeconds = widget.appState.selectedDuration * 60;
    _secondsRemaining = _totalSeconds;
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
    if (_isFocusing &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive)) {
      _killTree(reason: 'Вы покинули приложение! Дерево погибло');
    }
  }

  double get _growth =>
      _totalSeconds == 0 ? 0 : 1 - (_secondsRemaining / _totalSeconds);

  void _startFocus() {
    setState(() {
      _totalSeconds = widget.appState.selectedDuration * 60;
      _secondsRemaining = _totalSeconds;
      _isFocusing = true;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_secondsRemaining > 0) {
          _secondsRemaining--;
        } else {
          _finishFocus();
        }
      });
    });
  }

  void _finishFocus() {
    _timer?.cancel();
    final beforeCount = widget.appState.successfulSessions;
    widget.appState.addSession(FocusSession(
      date: DateTime.now(),
      durationMinutes: widget.appState.selectedDuration,
      success: true,
      speciesId: widget.appState.selectedSpeciesId,
    ));
    final afterCount = widget.appState.successfulSessions;
    final newlyUnlocked = treeSpecies
        .where((s) => s.unlockAt > beforeCount && s.unlockAt <= afterCount)
        .toList();

    if (widget.appState.soundEnabled) {
      SystemSound.play(SystemSoundType.click);
    }
    if (widget.appState.vibrationEnabled) {
      HapticFeedback.mediumImpact();
    }
    _isFocusing = false;

    if (newlyUnlocked.isNotEmpty) {
      showAppSnackBar(
        context,
        'Новый вид открыт: ${lower1(newlyUnlocked.first.name)}!',
        icon: Icons.auto_awesome_rounded,
      );
    } else {
      showAppSnackBar(
        context,
        'Дерево выросло! Отличная работа',
        icon: Icons.emoji_events_rounded,
      );
    }
  }

  void _killTree({required String reason}) {
    _timer?.cancel();
    widget.appState.addSession(FocusSession(
      date: DateTime.now(),
      durationMinutes: widget.appState.selectedDuration,
      success: false,
      speciesId: widget.appState.selectedSpeciesId,
    ));
    if (widget.appState.vibrationEnabled) {
      HapticFeedback.heavyImpact();
    }
    setState(() {
      _isFocusing = false;
    });
    showAppSnackBar(context, reason, icon: Icons.local_florist_rounded);
  }

  Future<void> _confirmGiveUp() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: 'Сдаться?',
      message: 'Если вы прервёте сеанс сейчас, дерево погибнет.',
      confirmLabel: 'Сдаться',
      icon: Icons.local_florist_outlined,
      destructive: true,
    );
    if (confirmed) {
      _killTree(reason: 'Вы сдались... Дерево погибло');
    }
  }

  Future<void> _pickCustomDuration() async {
    double value = widget.appState.selectedDuration.toDouble().clamp(1, 180);
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final scheme = Theme.of(context).colorScheme;
            return AlertDialog(
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Text('Своё время'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${value.round()} ${pluralizeRu(value.round(), 'минута', 'минуты', 'минут')}',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                  Slider(
                    value: value,
                    min: 1,
                    max: 180,
                    divisions: 179,
                    onChanged: (v) => setDialogState(() => value = v),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () {
                    widget.appState.setDuration(value.round());
                    Navigator.pop(context);
                  },
                  child: const Text('Готово'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSpeciesSelector(ColorScheme scheme) {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: treeSpecies.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final species = treeSpecies[index];
          final unlocked = widget.appState.isSpeciesUnlocked(species);
          final selected = widget.appState.selectedSpeciesId == species.id;
          return GestureDetector(
            onTap: () {
              if (unlocked) {
                widget.appState.setSpecies(species.id);
              } else {
                showAppSnackBar(
                  context,
                  'Откроется после ${species.unlockAt} ${pluralizeRu(species.unlockAt, 'дерева', 'деревьев', 'деревьев')}',
                  icon: Icons.lock_outline_rounded,
                );
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 78,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected ? scheme.primaryContainer : scheme.surfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(18),
                border: selected ? Border.all(color: scheme.primary, width: 2) : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    unlocked ? species.icon : Icons.lock_outline_rounded,
                    color: unlocked ? species.color : scheme.onSurfaceVariant,
                    size: 26,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    species.name,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: unlocked ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Кнопка-«пилюля» такого же вида, что и карточки видов деревьев —
  /// гарантированно тот же box-model, что убирает малейшие расхождения в
  /// выравнивании, которые были у стандартных ChoiceChip/ActionChip.
  Widget _pillButton(
    ColorScheme scheme, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : scheme.surfaceVariant.withOpacity(0.4),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDurationChips(ColorScheme scheme) {
    const presets = [5, 10, 15, 25];
    final isCustom = !presets.contains(widget.appState.selectedDuration);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        ...presets.map((minutes) => _pillButton(
              scheme,
              label: '$minutes мин',
              selected: widget.appState.selectedDuration == minutes,
              onTap: () => widget.appState.setDuration(minutes),
            )),
        _pillButton(
          scheme,
          label: isCustom ? '${widget.appState.selectedDuration} мин' : 'своё',
          selected: isCustom,
          icon: Icons.tune_rounded,
          onTap: _pickCustomDuration,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final species = speciesById(widget.appState.selectedSpeciesId);
    final fullName =
        '${widget.appState.userName} ${widget.appState.lastName}'.trim();

    return WillPopScope(
      onWillPop: () async {
        if (_isFocusing) {
          _confirmGiveUp();
          return false;
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(fullName),
          actions: [
            IconButton(
              icon: const Icon(Icons.insights_rounded),
              tooltip: 'Статистика',
              onPressed: _isFocusing
                  ? null
                  : () => Navigator.push(
                        context,
                        smoothRoute(StatsScreen(appState: widget.appState)),
                      ),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Настройки',
              onPressed: _isFocusing
                  ? null
                  : () => Navigator.push(
                        context,
                        smoothRoute(SettingsScreen(appState: widget.appState)),
                      ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (!_isFocusing) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Вид дерева',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _buildSpeciesSelector(scheme),
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Время фокуса',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _buildDurationChips(scheme),
                ),
                const SizedBox(height: 18),
              ],
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: scheme.surfaceVariant.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          padding: const EdgeInsets.all(34),
                          decoration: BoxDecoration(
                            color: Color.lerp(
                                scheme.primaryContainer, species.color, _growth * 0.4),
                            shape: BoxShape.circle,
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 350),
                            switchInCurve: Curves.easeOutBack,
                            switchOutCurve: Curves.easeIn,
                            transitionBuilder: (child, animation) => ScaleTransition(
                              scale: animation,
                              child: FadeTransition(opacity: animation, child: child),
                            ),
                            child: Icon(
                              growthIcon(_growth, species),
                              key: ValueKey('${species.id}-${growthIcon(_growth, species)}'),
                              size: 84,
                              color: _growth >= 0.75 ? species.color : scheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          _isFocusing
                              ? '${_secondsRemaining ~/ 60}:${(_secondsRemaining % 60).toString().padLeft(2, '0')}'
                              : 'Посадите ${lower1(species.name)} на ${widget.appState.selectedDuration} ${pluralizeRu(widget.appState.selectedDuration, 'минуту', 'минуты', 'минут')}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        if (_isFocusing) ...[
                          const SizedBox(height: 18),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 44),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: _growth,
                                minHeight: 8,
                                backgroundColor: scheme.surfaceVariant,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Не выходите из приложения — дерево погибнет',
                            style:
                                TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SizedBox(
                  width: double.infinity,
                  child: _isFocusing
                      ? OutlinedButton(
                          onPressed: _confirmGiveUp,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            foregroundColor: scheme.error,
                            side: BorderSide(color: scheme.error.withOpacity(0.4)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18)),
                          ),
                          child: const Text('Сдаться',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                        )
                      : FilledButton(
                          onPressed: _startFocus,
                          child: const Text('Посадить дерево'),
                        ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Экран статистики и леса
// ---------------------------------------------------------------------------

class StatsScreen extends StatelessWidget {
  final AppState appState;
  const StatsScreen({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final history = appState.history;
        return Scaffold(
          appBar: AppBar(title: const Text('Статистика')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 1.4,
                  children: [
                    _StatCard(
                      icon: Icons.park_rounded,
                      label: 'Деревьев выросло',
                      value: '${appState.successfulSessions}',
                    ),
                    _StatCard(
                      icon: Icons.timer_outlined,
                      label: 'Время в фокусе',
                      value: formatMinutes(appState.totalFocusMinutes),
                    ),
                    _StatCard(
                      icon: Icons.local_fire_department_rounded,
                      label: 'Серия дней',
                      value: '${appState.currentStreak}',
                    ),
                    _StatCard(
                      icon: Icons.percent_rounded,
                      label: 'Успешных сеансов',
                      value: '${(appState.successRate * 100).round()}%',
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Text(
                  'Мой лес',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface),
                ),
                const SizedBox(height: 12),
                if (history.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(28),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: scheme.surfaceVariant.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.forest_outlined, size: 40, color: scheme.onSurfaceVariant),
                        const SizedBox(height: 10),
                        Text(
                          'Пока нет посаженных деревьев',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                    ),
                    itemCount: history.length,
                    itemBuilder: (context, index) {
                      final session = history[index];
                      final species = speciesById(session.speciesId);
                      return Tooltip(
                        message:
                            '${session.date.day}.${session.date.month}.${session.date.year} · ${session.durationMinutes} мин',
                        child: Container(
                          decoration: BoxDecoration(
                            color: session.success
                                ? species.color.withOpacity(0.18)
                                : scheme.errorContainer.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            session.success
                                ? species.icon
                                : Icons.local_florist_outlined,
                            color: session.success ? species.color : scheme.onErrorContainer,
                          ),
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 28),
                Text(
                  'Виды деревьев',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface),
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.95,
                  ),
                  itemCount: treeSpecies.length,
                  itemBuilder: (context, index) {
                    final species = treeSpecies[index];
                    final unlocked = appState.isSpeciesUnlocked(species);
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: scheme.surfaceVariant.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            unlocked ? species.icon : Icons.lock_outline_rounded,
                            color: unlocked ? species.color : scheme.onSurfaceVariant,
                            size: 26,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            species.name,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: unlocked ? scheme.onSurface : scheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          if (!unlocked) ...[
                            const SizedBox(height: 2),
                            Text(
                              '${species.unlockAt} ${pluralizeRu(species.unlockAt, 'дерево', 'дерева', 'деревьев')}',
                              style:
                                  TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 28),
                if (history.isNotEmpty) ...[
                  Text(
                    'История',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface),
                  ),
                  const SizedBox(height: 12),
                  ...history.take(20).map((session) {
                    final species = speciesById(session.speciesId);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: scheme.surfaceVariant.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            session.success
                                ? Icons.check_circle_rounded
                                : Icons.cancel_rounded,
                            color: session.success ? species.color : scheme.error,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '${species.name} · ${session.durationMinutes} ${pluralizeRu(session.durationMinutes, 'минута', 'минуты', 'минут')} · ${session.date.day}.${session.date.month.toString().padLeft(2, '0')}.${session.date.year}',
                              style: TextStyle(color: scheme.onSurface),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatCard({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceVariant.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: scheme.primary, size: 24),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: scheme.onSurface),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Экран настроек
// ---------------------------------------------------------------------------

class SettingsScreen extends StatelessWidget {
  final AppState appState;
  const SettingsScreen({super.key, required this.appState});

  Future<void> _editName(BuildContext context) async {
    final nameController = TextEditingController(text: appState.userName);
    final lastNameController = TextEditingController(text: appState.lastName);
    final scheme = Theme.of(context).colorScheme;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Изменить имя'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              maxLength: 20,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Имя',
                filled: true,
                fillColor: scheme.surfaceVariant,
                counterText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: lastNameController,
              maxLength: 20,
              decoration: InputDecoration(
                hintText: 'Фамилия',
                filled: true,
                fillColor: scheme.surfaceVariant,
                counterText: '',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              final lastName = lastNameController.text.trim();
              if (name.isNotEmpty) {
                appState.setUserName(name);
              }
              if (lastName.isNotEmpty) {
                appState.setLastName(lastName);
              }
              Navigator.pop(context);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickReminderTime(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: appState.reminderHour, minute: appState.reminderMinute),
    );
    if (picked != null) {
      await appState.setReminderTime(picked.hour, picked.minute);
      if (context.mounted) {
        showAppSnackBar(context, 'Время напоминания обновлено', icon: Icons.alarm_rounded);
      }
    }
  }

  Future<void> _confirmResetEverything(BuildContext context) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: 'Сбросить все настройки?',
      message:
          'Все данные будут удалены без возможности восстановления: лес, регистрация и настройки. Вы вернётесь на экран приветствия.',
      confirmLabel: 'Сбросить',
      icon: Icons.restart_alt_rounded,
      destructive: true,
    );
    if (confirmed) {
      await appState.resetEverything();
      if (context.mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final fullName = '${appState.userName} ${appState.lastName}'.trim();
        return Scaffold(
          appBar: AppBar(title: const Text('Настройки')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.surfaceVariant.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Icon(Icons.person_rounded, color: scheme.primary),
                    ),
                    title: Text(fullName, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('Изменить имя'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _editName(context),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Уведомления',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceVariant.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('Ежедневное напоминание'),
                        subtitle: const Text('Напоминать посадить дерево'),
                        value: appState.notificationsEnabled,
                        onChanged: (v) => appState.toggleNotifications(v),
                        secondary: const Icon(Icons.notifications_outlined),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.alarm_rounded),
                        title: const Text('Время напоминания'),
                        subtitle: Text(formatTimeOfDay(appState.reminderHour, appState.reminderMinute)),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        enabled: appState.notificationsEnabled,
                        onTap: () => _pickReminderTime(context),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        title: const Text('Звук'),
                        subtitle: const Text('Звук при завершении сеанса'),
                        value: appState.soundEnabled,
                        onChanged: appState.toggleSound,
                        secondary: const Icon(Icons.volume_up_outlined),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        title: const Text('Вибрация'),
                        subtitle: const Text('Вибрация при событиях'),
                        value: appState.vibrationEnabled,
                        onChanged: appState.toggleVibration,
                        secondary: const Icon(Icons.vibration_rounded),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Если уведомления не приходят: откройте настройки телефона → приложения → Grove → уведомления, и отключите ограничение батареи/автозапуска (особенно на Xiaomi, Huawei, Honor).',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant, height: 1.4),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Данные',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceVariant.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: ListTile(
                    leading: Icon(Icons.restart_alt_rounded, color: scheme.error),
                    title: Text('Сбросить все настройки', style: TextStyle(color: scheme.error)),
                    onTap: () => _confirmResetEverything(context),
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Text('Grove · v1.2',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
