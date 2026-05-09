import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'login.dart'; // added import
import 'home_screen.dart'; // added
import '../services/fcm_service.dart';
import '../services/language_preference_service.dart';
import '../theme/app_theme.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController nameController = TextEditingController();
  final TextEditingController ageController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController emergencyPhoneController = TextEditingController();

  String userType = 'Client';
  String preferredLanguage = 'English';

  bool isLoading = false;
  bool _obscurePassword = true;

  Future<void> registerUser() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => isLoading = true);

    try {
      // 1️⃣ Create user in Firebase Auth
      UserCredential userCredential =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      String uid = userCredential.user!.uid;

      // 2️⃣ Save extra details in Firestore
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'name': nameController.text.trim(),
        'age': int.parse(ageController.text.trim()),
        'email': emailController.text.trim(),
        'userType': userType,
        'preferredLanguage': preferredLanguage,
        'emergencyPhone': emergencyPhoneController.text.trim(),
        'createdAt': Timestamp.now(),
      });

      // Apply the language preference immediately
      LanguagePreferenceService().setPreference(preferredLanguage);

      // Save FCM token for push notifications (if it fails, still proceed with registration)
      try {
        await FcmService().saveTokenForCurrentUser();
      } catch (e) {
        debugPrint('FCM save token ignored during registration: $e');
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Account Created Successfully")),
      );

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) =>  HomeScreen(title: " to Life Lens")),
      );
       
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Auth Error: ${e.message}")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    }

    if (mounted) setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                // Back button
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
                const SizedBox(height: 32),
                // Header Icon
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: AppTheme.accentGradient,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: AppTheme.glowShadow(AppTheme.accent),
                  ),
                  child: const Icon(Icons.person_add_outlined,
                      color: Colors.white, size: 28),
                ),
                const SizedBox(height: 24),
                Text(
                  'Create Account',
                  style: GoogleFonts.inter(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Sign up to get started',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 32),
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      // Name
                      TextFormField(
                        controller: nameController,
                        style: GoogleFonts.inter(color: AppTheme.textPrimary),
                        decoration: const InputDecoration(
                          labelText: "Full Name",
                          prefixIcon: Icon(Icons.person_outline,
                              color: AppTheme.textSecondary, size: 20),
                        ),
                        validator: (value) =>
                            value!.isEmpty ? "Enter your name" : null,
                      ),
                      const SizedBox(height: 16),
                      // Age
                      TextFormField(
                        controller: ageController,
                        keyboardType: TextInputType.number,
                        style: GoogleFonts.inter(color: AppTheme.textPrimary),
                        decoration: const InputDecoration(
                          labelText: "Age",
                          prefixIcon: Icon(Icons.cake_outlined,
                              color: AppTheme.textSecondary, size: 20),
                        ),
                        validator: (value) =>
                            value!.isEmpty ? "Enter your age" : null,
                      ),
                      const SizedBox(height: 16),
                      // Email
                      TextFormField(
                        controller: emailController,
                        style: GoogleFonts.inter(color: AppTheme.textPrimary),
                        decoration: const InputDecoration(
                          labelText: "Email",
                          prefixIcon: Icon(Icons.email_outlined,
                              color: AppTheme.textSecondary, size: 20),
                        ),
                        validator: (value) =>
                            value!.isEmpty ? "Enter your email" : null,
                      ),
                      const SizedBox(height: 16),
                      // Password
                      TextFormField(
                        controller: passwordController,
                        obscureText: _obscurePassword,
                        style: GoogleFonts.inter(color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          labelText: "Password",
                          prefixIcon: const Icon(Icons.lock_outline,
                              color: AppTheme.textSecondary, size: 20),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: AppTheme.textSecondary,
                              size: 20,
                            ),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: (value) =>
                            value!.length < 6 ? "Minimum 6 characters" : null,
                      ),
                      const SizedBox(height: 16),
                      // User Type
                      DropdownButtonFormField<String>(
                        initialValue: userType,
                        dropdownColor: AppTheme.card,
                        style: GoogleFonts.inter(color: AppTheme.textPrimary),
                        decoration: const InputDecoration(
                          labelText: "User Type",
                          prefixIcon: Icon(Icons.badge_outlined,
                              color: AppTheme.textSecondary, size: 20),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: 'Client', child: Text('Client')),
                          DropdownMenuItem(
                              value: 'Volunteer', child: Text('Volunteer')),
                        ],
                        onChanged: (val) {
                          if (val != null) setState(() => userType = val);
                        },
                        validator: (value) =>
                            (value == null || value.isEmpty)
                                ? "Select user type"
                                : null,
                      ),
                      const SizedBox(height: 16),
                      // Preferred Language
                      DropdownButtonFormField<String>(
                        value: preferredLanguage,
                        dropdownColor: AppTheme.card,
                        style: GoogleFonts.inter(color: AppTheme.textPrimary),
                        decoration: const InputDecoration(
                          labelText: "Preferred Language to Listen",
                          prefixIcon: Icon(Icons.translate_rounded,
                              color: AppTheme.textSecondary, size: 20),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: 'English', child: Text('English')),
                          DropdownMenuItem(
                              value: 'Hindi', child: Text('Hindi')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => preferredLanguage = val);
                          }
                        },
                        validator: (value) =>
                            (value == null || value.isEmpty)
                                ? "Select preferred language"
                                : null,
                      ),
                      const SizedBox(height: 16),
                      // Emergency Phone
                      TextFormField(
                        controller: emergencyPhoneController,
                        keyboardType: TextInputType.phone,
                        style: GoogleFonts.inter(color: AppTheme.textPrimary),
                        decoration: const InputDecoration(
                          labelText: "Emergency Phone Number",
                          prefixIcon: Icon(Icons.phone_outlined,
                              color: AppTheme.textSecondary, size: 20),
                        ),
                        validator: (value) =>
                            value!.isEmpty
                                ? "Enter emergency phone number"
                                : null,
                      ),
                      const SizedBox(height: 28),
                      // Register Button
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton(
                          onPressed: isLoading ? null : registerUser,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.accent,
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppTheme.radiusMd),
                            ),
                          ),
                          child: isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Text(
                                  "Create Account",
                                  style: GoogleFonts.inter(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Login Button
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const LoginScreen()),
                            );
                          },
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                                color: AppTheme.cardBorder, width: 1.5),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppTheme.radiusMd),
                            ),
                          ),
                          child: Text("Login",
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textSecondary,
                              )),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}