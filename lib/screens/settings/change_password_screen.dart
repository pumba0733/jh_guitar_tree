// lib/screens/settings/change_password_screen.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _pwd = TextEditingController();
  final _pwd2 = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    if (_pwd.text != _pwd2.text) {
      setState(() => _error = '비밀번호가 일치하지 않습니다.');
      return;
    }
    setState(() => _error = null);
    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth.updateUser(UserAttributes(password: _pwd.text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('비밀번호가 변경되었습니다.')));
      Navigator.pop(context);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _pwd.dispose();
    _pwd2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('비밀번호 변경')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _pwd,
              decoration: const InputDecoration(labelText: '새 비밀번호'),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pwd2,
              decoration: const InputDecoration(labelText: '새 비밀번호 확인'),
              obscureText: true,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loading ? null : _submit,
              child: _loading ? const CircularProgressIndicator() : const Text('변경'),
            )
          ],
        ),
      ),
    );
  }
}
