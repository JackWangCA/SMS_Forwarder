class SmsMessageModel {
  final int? id;
  final String address;
  final String body;
  final DateTime date;

  SmsMessageModel({
    this.id,
    required this.address,
    required this.body,
    required this.date,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'address': address,
      'body': body,
      'date': date.millisecondsSinceEpoch,
    };
  }

  factory SmsMessageModel.fromMap(Map<String, dynamic> map) {
    return SmsMessageModel(
      id: map['id'],
      address: map['address'],
      body: map['body'],
      date: DateTime.fromMillisecondsSinceEpoch(map['date']),
    );
  }
}