import 'dart:io';

class LocalIpService {
  const LocalIpService();

  Future<String> bestAddress() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final value = address.address;
        if (value.startsWith('192.168.') ||
            value.startsWith('10.') ||
            value.startsWith('172.16.') ||
            value.startsWith('172.17.') ||
            value.startsWith('172.18.') ||
            value.startsWith('172.19.') ||
            value.startsWith('172.20.') ||
            value.startsWith('172.21.') ||
            value.startsWith('172.22.') ||
            value.startsWith('172.23.') ||
            value.startsWith('172.24.') ||
            value.startsWith('172.25.') ||
            value.startsWith('172.26.') ||
            value.startsWith('172.27.') ||
            value.startsWith('172.28.') ||
            value.startsWith('172.29.') ||
            value.startsWith('172.30.') ||
            value.startsWith('172.31.')) {
          return value;
        }
      }
    }
    if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
      return interfaces.first.addresses.first.address;
    }
    return InternetAddress.loopbackIPv4.address;
  }
}
