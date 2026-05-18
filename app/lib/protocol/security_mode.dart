enum SecurityMode {
  none(0),
  wep(1),
  wpa1(2),
  wpa2(3),
  wpa12(4);

  const SecurityMode(this.code);

  final int code;
}
