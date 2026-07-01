import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/fcm_service.dart';
import '../services/language_preference_service.dart';
import '../theme/app_theme.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  late Future<DocumentSnapshot<Map<String, dynamic>>> _userDoc;
  Map<String, dynamic>? _cachedData;

  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emergencyCtrl = TextEditingController();

  String _preferredLanguage = 'English';

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
          _cachedData = data;
          _nameCtrl.text = (data['name'] ?? '').toString();
          _ageCtrl.text = (data['age'] ?? '').toString();
          _phoneCtrl.text = (data['phone'] ?? '').toString();
          _emergencyCtrl.text = (data['emergencyPhone'] ?? '').toString();
          _preferredLanguage = (data['preferredLanguage'] ?? 'English').toString();
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
        'preferredLanguage': _preferredLanguage,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      await FirebaseFirestore.instance.collection('users').doc(uid).set(data, SetOptions(merge: true));

      // Update the language preference singleton immediately
      LanguagePreferenceService().setPreference(_preferredLanguage);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile updated')));
      setState(() => _editing = false);
      // refresh
      setState(() {
        _cachedData = data;
        _userDoc = FirebaseFirestore.instance.collection('users').doc(uid).get();
      });
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
        backgroundColor: AppTheme.bg,
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
          child: Center(
            child: Text('Not signed in',
                style: GoogleFonts.inter(color: AppTheme.textSecondary)),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.of(context).maybePop(),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppTheme.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: const Icon(Icons.arrow_back_ios_new,
                            color: AppTheme.textSecondary, size: 18),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text('Profile',
                        style: GoogleFonts.inter(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        )),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _editing = !_editing),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _editing
                              ? AppTheme.red.withOpacity(0.15)
                              : AppTheme.accent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _editing
                                ? AppTheme.red.withOpacity(0.4)
                                : AppTheme.accent.withOpacity(0.3),
                          ),
                        ),
                        child: Icon(
                          _editing ? Icons.close : Icons.edit_outlined,
                          color: _editing ? AppTheme.red : AppTheme.accent,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Body
              Expanded(
                child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  future: _userDoc,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(color: AppTheme.accent),
                      );
                    }
                    if (!snapshot.hasData ||
                        snapshot.data == null ||
                        !snapshot.data!.exists) {
                      return Center(
                        child: Text('Profile not found',
                            style: GoogleFonts.inter(
                                color: AppTheme.textSecondary)),
                      );
                    }
                    final data = snapshot.data!.data()!;
                    final email = data['email'] ??
                        FirebaseAuth.instance.currentUser?.email ??
                        '';
                    final userType = data['userType'] ?? '';

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        children: [
                          // Profile card
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: AppTheme.glassCard,
                            child: Row(
                              children: [
                                Container(
                                  width: 64,
                                  height: 64,
                                  decoration: BoxDecoration(
                                    gradient: AppTheme.accentGradient,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Center(
                                    child: Text(
                                      (data['name'] ?? '').toString().isNotEmpty
                                          ? (data['name'][0] ?? '')
                                          : '?',
                                      style: GoogleFonts.inter(
                                        fontSize: 26,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        data['name'] ?? '',
                                        style: GoogleFonts.inter(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w700,
                                          color: AppTheme.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        email.toString(),
                                        style: GoogleFonts.inter(
                                          color: AppTheme.textSecondary,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 4),
                                        decoration: BoxDecoration(
                                          color:
                                              AppTheme.accent.withOpacity(0.12),
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          border: Border.all(
                                            color: AppTheme.accent
                                                .withOpacity(0.3),
                                          ),
                                        ),
                                        child: Text(
                                          userType.toString(),
                                          style: GoogleFonts.inter(
                                            color: AppTheme.accent,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          // Form
                          Expanded(
                            child: Form(
                              key: _formKey,
                              child: ListView(
                                children: [
                                  TextFormField(
                                    controller: _nameCtrl,
                                    enabled: _editing,
                                    style: GoogleFonts.inter(
                                        color: AppTheme.textPrimary),
                                    decoration: const InputDecoration(
                                      labelText: 'Full name',
                                      prefixIcon: Icon(Icons.person_outline,
                                          color: AppTheme.textSecondary,
                                          size: 20),
                                    ),
                                    validator: (v) =>
                                        v == null || v.trim().isEmpty
                                            ? 'Enter name'
                                            : null,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _ageCtrl,
                                    enabled: _editing,
                                    keyboardType: TextInputType.number,
                                    style: GoogleFonts.inter(
                                        color: AppTheme.textPrimary),
                                    decoration: const InputDecoration(
                                      labelText: 'Age',
                                      prefixIcon: Icon(Icons.cake_outlined,
                                          color: AppTheme.textSecondary,
                                          size: 20),
                                    ),
                                    validator: (v) {
                                      if (!_editing) return null;
                                      if (v == null || v.trim().isEmpty)
                                        return 'Enter age';
                                      if (int.tryParse(v) == null)
                                        return 'Enter valid number';
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _phoneCtrl,
                                    enabled: _editing,
                                    keyboardType: TextInputType.phone,
                                    style: GoogleFonts.inter(
                                        color: AppTheme.textPrimary),
                                    decoration: const InputDecoration(
                                      labelText: 'Phone',
                                      prefixIcon: Icon(Icons.phone_outlined,
                                          color: AppTheme.textSecondary,
                                          size: 20),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _emergencyCtrl,
                                    enabled: _editing,
                                    keyboardType: TextInputType.phone,
                                    style: GoogleFonts.inter(
                                        color: AppTheme.textPrimary),
                                    decoration: const InputDecoration(
                                      labelText: 'Emergency phone',
                                      prefixIcon: Icon(
                                          Icons.emergency_outlined,
                                          color: AppTheme.textSecondary,
                                          size: 20),
                                    ),
                                    validator: (v) {
                                      if (!_editing) return null;
                                      if (v == null || v.trim().isEmpty)
                                        return 'Enter emergency phone';
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 14),
                                  // Preferred Language
                                  DropdownButtonFormField<String>(
                                    value: _preferredLanguage,
                                    dropdownColor: AppTheme.card,
                                    style: GoogleFonts.inter(
                                        color: AppTheme.textPrimary),
                                    decoration: const InputDecoration(
                                      labelText: 'Preferred Language to Listen',
                                      prefixIcon: Icon(
                                          Icons.translate_rounded,
                                          color: AppTheme.textSecondary,
                                          size: 20),
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                          value: 'English',
                                          child: Text('English')),
                                      DropdownMenuItem(
                                          value: 'Hindi',
                                          child: Text('Hindi')),
                                    ],
                                    onChanged: _editing
                                        ? (val) {
                                            if (val != null) {
                                              setState(() =>
                                                  _preferredLanguage = val);
                                            }
                                          }
                                        : null,
                                  ),
                                  const SizedBox(height: 24),
                                  if (_editing)
                                    Row(
                                      children: [
                                        Expanded(
                                          child: SizedBox(
                                            height: 50,
                                            child: ElevatedButton(
                                              onPressed: _loading
                                                  ? null
                                                  : _saveProfile,
                                              child: _loading
                                                  ? const SizedBox(
                                                      height: 20,
                                                      width: 20,
                                                      child:
                                                          CircularProgressIndicator(
                                                        color: Colors.white,
                                                        strokeWidth: 2,
                                                      ),
                                                    )
                                                  : Text('Save',
                                                      style: GoogleFonts.inter(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      )),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: SizedBox(
                                            height: 50,
                                            child: OutlinedButton(
                                              onPressed: _loading
                                                  ? null
                                                  : () {
                                                      setState(() => _editing = false);
                                                      // Restore from cache instead of re-fetching
                                                      final d = _cachedData;
                                                      if (d != null) {
                                                        _nameCtrl.text = (d['name'] ?? '').toString();
                                                        _ageCtrl.text = (d['age'] ?? '').toString();
                                                        _phoneCtrl.text = (d['phone'] ?? '').toString();
                                                        _emergencyCtrl.text = (d['emergencyPhone'] ?? '').toString();
                                                        setState(() {
                                                          _preferredLanguage = (d['preferredLanguage'] ?? 'English').toString();
                                                        });
                                                      }
                                                    },
                                              child: Text('Cancel',
                                                  style: GoogleFonts.inter(
                                                    fontWeight: FontWeight.w600,
                                                    color:
                                                        AppTheme.textSecondary,
                                                  )),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: double.infinity,
                                    child: TextButton(
                                      onPressed: () async {
                                        // Clear FCM token so old account stops getting notifications
                                        await FcmService().clearTokenForCurrentUser();
                                        await FirebaseAuth.instance.signOut();
                                        if (mounted)
                                          Navigator.of(context).pop();
                                      },
                                      child: Text('Sign out',
                                          style: GoogleFonts.inter(
                                            color: AppTheme.red,
                                            fontWeight: FontWeight.w600,
                                          )),
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
