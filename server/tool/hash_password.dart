import 'package:bcrypt/bcrypt.dart';

void main() {
  const password = 'ChangeMe123!';

  print(BCrypt.hashpw(password, BCrypt.gensalt()));
}
