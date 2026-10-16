import 'package:bcrypt/bcrypt.dart';

void main() {
  const password = 'test123';

  // ignore: avoid_print
  print(BCrypt.hashpw(password, BCrypt.gensalt()));
}
