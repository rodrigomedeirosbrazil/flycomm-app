import 'package:flutter/material.dart';

import 'app.dart';
import 'env.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Env.assertConfigured();
  runApp(const FlycommApp());
}
