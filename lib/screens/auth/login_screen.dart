import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/screens/auth/login_controller.dart';
import 'package:jh_guitar_tree/widgets/login_input_field.dart';
import 'package:jh_guitar_tree/dialogs/staff_login_dialog.dart';


class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController nameController = TextEditingController();
  bool isLoading = false;

  void _attemptLogin() async {
    final name = nameController.text.trim();
    if (name.isEmpty) return;

    setState(() => isLoading = true);
    await LoginController(context).handleStudentLogin(name);
    setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 우측 상단 강사 로그인 버튼
          Positioned(
            top: 40,
            right: 20,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.lock_outline),
              label: const Text('강사 로그인'),
              onPressed: () {
  showDialog(
    context: context,
    builder: (_) => const StaffLoginDialog(),
  );
},

            ),
          ),
          // 학생 로그인 화면
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '🎯 인조이 기타학원',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                const Text('🧑‍🎓 학생 로그인', style: TextStyle(fontSize: 18)),
                const SizedBox(height: 12),
                SizedBox(
                  width: 220,
                  child: LoginInputField(
                    controller: nameController,
                    hintText: '이름 입력',
                    onSubmitted: (_) => _attemptLogin(),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: isLoading ? null : _attemptLogin,
                  child:
                      isLoading
                          ? const CircularProgressIndicator()
                          : const Text('로그인 ▶'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
