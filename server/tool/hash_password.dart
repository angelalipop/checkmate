import 'package:bcrypt/bcrypt.dart';

void main() {
  const password = 'test123';
  print(BCrypt.hashpw(password, BCrypt.gensalt()));
}
