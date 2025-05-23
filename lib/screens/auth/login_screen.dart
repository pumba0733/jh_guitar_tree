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
            child: IconButton(
              icon: const Icon(Icons.manage_accounts),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (_) => const StaffLoginDialog(),
                );
              },
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '🎸 기타 레슨 앱',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  LoginInputField(
                    controller: nameController,
                    hintText: '이름을 입력하세요',
                    onSubmitted: (_) => _attemptLogin(),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: isLoading ? null : _attemptLogin,
                    child:
                        isLoading
                            ? const CircularProgressIndicator()
                            : const Text('로그인'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
