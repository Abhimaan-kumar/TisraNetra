import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  late Future<DocumentSnapshot<Map<String, dynamic>>> _userDoc;

  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emergencyCtrl = TextEditingController();

  bool _loading = false;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    if (uid != null) {
      _userDoc = FirebaseFirestore.instance.collection('users').doc(uid).get();
      _userDoc.then((doc) {
        final data = doc.data();
        if (data != null) {
          _nameCtrl.text = (data['name'] ?? '').toString();
          _ageCtrl.text = (data['age'] ?? '').toString();
          _phoneCtrl.text = (data['phone'] ?? '').toString();
          _emergencyCtrl.text = (data['emergencyPhone'] ?? '').toString();
        }
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _phoneCtrl.dispose();
    _emergencyCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final data = {
        'name': _nameCtrl.text.trim(),
        'age': int.tryParse(_ageCtrl.text.trim()) ?? 0,
        'phone': _phoneCtrl.text.trim(),
        'emergencyPhone': _emergencyCtrl.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      await FirebaseFirestore.instance.collection('users').doc(uid).set(data, SetOptions(merge: true));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile updated')));
      setState(() => _editing = false);
      // refresh
      setState(() => _userDoc = FirebaseFirestore.instance.collection('users').doc(uid).get());
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: const Center(child: Text('Not signed in')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            icon: Icon(_editing ? Icons.close : Icons.edit),
            onPressed: () => setState(() => _editing = !_editing),
          ),
        ],
      ),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: _userDoc,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data == null || !snapshot.data!.exists) {
            return const Center(child: Text('Profile not found'));
          }
          final data = snapshot.data!.data()!;
          final email = data['email'] ?? FirebaseAuth.instance.currentUser?.email ?? '';
          final userType = data['userType'] ?? '';

          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 36,
                          backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                          child: Text(
                            (data['name'] ?? '').toString().isNotEmpty ? (data['name'][0] ?? '') : '?',
                            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(data['name'] ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text(email.toString(), style: const TextStyle(color: Colors.grey)),
                              const SizedBox(height: 6),
                              Chip(label: Text(userType.toString())),
                            ],
                          ),
                        )
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      children: [
                        TextFormField(
                          controller: _nameCtrl,
                          enabled: _editing,
                          decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
                          validator: (v) => v == null || v.trim().isEmpty ? 'Enter name' : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _ageCtrl,
                          enabled: _editing,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Age', border: OutlineInputBorder()),
                          validator: (v) {
                            if (!_editing) return null;
                            if (v == null || v.trim().isEmpty) return 'Enter age';
                            if (int.tryParse(v) == null) return 'Enter valid number';
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _phoneCtrl,
                          enabled: _editing,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Phone', border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _emergencyCtrl,
                          enabled: _editing,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Emergency phone', border: OutlineInputBorder()),
                          validator: (v) {
                            if (!_editing) return null;
                            if (v == null || v.trim().isEmpty) return 'Enter emergency phone';
                            return null;
                          },
                        ),
                        const SizedBox(height: 20),
                        if (_editing)
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _loading ? null : _saveProfile,
                                  child: _loading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('Save'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: _loading
                                      ? null
                                      : () {
                                          setState(() => _editing = false);
                                          // restore values from snapshot
                                          setState(() => _userDoc = FirebaseFirestore.instance.collection('users').doc(uid).get());
                                          _userDoc.then((doc) {
                                            final d = doc.data();
                                            if (d != null) {
                                              _nameCtrl.text = (d['name'] ?? '').toString();
                                              _ageCtrl.text = (d['age'] ?? '').toString();
                                              _phoneCtrl.text = (d['phone'] ?? '').toString();
                                              _emergencyCtrl.text = (d['emergencyPhone'] ?? '').toString();
                                            }
                                          });
                                        },
                                  child: const Text('Cancel'),
                                ),
                              ),
                            ],
                          ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: () async {
                              await FirebaseAuth.instance.signOut();
                              if (mounted) Navigator.of(context).pop();
                            },
                            child: const Text('Sign out', style: TextStyle(color: Colors.red)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
