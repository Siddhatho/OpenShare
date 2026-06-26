import 'dart:math';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PokemonIdentity {
  const PokemonIdentity({
    required this.name,
    required this.spriteUrl,
  });

  final String name;
  final String spriteUrl;

  String get displayName => _capitalize(name);

  static String _capitalize(String value) {
    if (value.isEmpty) {
      return value;
    }
    return value[0].toUpperCase() + value.substring(1);
  }
}

class PokemonIdentityService {
  PokemonIdentityService({
    Dio? dio,
    Random? random,
  })  : _dio = dio ?? Dio(),
        _random = random ?? Random();

  static const _nameKey = 'pokemon_name';
  static const _spriteKey = 'pokemon_sprite';

  final Dio _dio;
  final Random _random;

  Future<PokemonIdentity> load() async {
    final preferences = await SharedPreferences.getInstance();
    final id = _random.nextInt(151) + 1;
    final response = await _dio.getUri<Map<String, Object?>>(
      Uri.https('pokeapi.co', '/api/v2/pokemon/$id'),
    );
    final data = response.data;
    final name = data?['name'] as String?;
    final sprites = data?['sprites'] as Map<String, Object?>?;
    final spriteUrl = sprites?['front_default'] as String?;
    if (!_hasValue(name) || !_hasValue(spriteUrl)) {
      throw StateError('PokeAPI returned an incomplete Pokémon profile.');
    }

    await preferences.setString(_nameKey, name!);
    await preferences.setString(_spriteKey, spriteUrl!);
    return PokemonIdentity(name: name, spriteUrl: spriteUrl);
  }

  bool _hasValue(String? value) => value != null && value.isNotEmpty;
}
