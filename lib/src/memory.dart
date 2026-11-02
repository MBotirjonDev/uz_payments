import 'click/models.dart';
import 'payme/models.dart';

/// In-memory [PaymeBackend] for tests, demos and the Payme sandbox.
///
/// Not for production: data is lost on restart and nothing is atomic across
/// processes. Use it as a reference for your database implementation.
class InMemoryPaymeBackend implements PaymeBackend {
  /// Orders by id, with their amount in tiyin.
  final Map<String, int> orders = {};

  /// Order ids that are already paid.
  final Set<String> paid = {};

  /// Order ids whose goods are delivered, so a performed transaction cannot be refunded.
  final Set<String> delivered = {};

  /// Transactions by Payme id.
  final Map<String, PaymeTransaction> transactions = {};

  /// The account field that holds the order id.
  final String accountField;

  InMemoryPaymeBackend({this.accountField = 'order_id'});

  var _seq = 0;

  @override
  Future<PaymeOrder?> findOrder(Map<String, dynamic> account) async {
    final id = account[accountField]?.toString();
    final amount = id == null ? null : orders[id];
    if (id == null || amount == null) return null;
    return PaymeOrder(id: id, amountTiyin: amount, payable: !paid.contains(id));
  }

  @override
  Future<PaymeTransaction?> findTransaction(String paymeId) async => transactions[paymeId]?.copy();

  @override
  Future<PaymeTransaction?> findOpenTransactionForOrder(String orderId) async {
    for (final tx in transactions.values) {
      if (tx.orderId == orderId && (tx.state == PaymeState.created || tx.state == PaymeState.performed)) {
        return tx.copy();
      }
    }
    return null;
  }

  @override
  Future<PaymeTransaction> insertTransaction(PaymeTransaction tx) async {
    if (transactions.containsKey(tx.paymeId)) throw StateError('duplicate Payme id ${tx.paymeId}');
    tx.merchantId = '${++_seq}';
    transactions[tx.paymeId] = tx.copy();
    return tx;
  }

  @override
  Future<void> perform(PaymeTransaction tx) async {
    transactions[tx.paymeId] = tx.copy();
    paid.add(tx.orderId);
  }

  @override
  Future<void> cancel(PaymeTransaction tx) async {
    transactions[tx.paymeId] = tx.copy();
    paid.remove(tx.orderId);
  }

  @override
  Future<bool> canCancelPerformed(PaymeTransaction tx) async => !delivered.contains(tx.orderId);

  @override
  Future<List<PaymeTransaction>> transactionsBetween(int from, int to) async => [
        for (final tx in transactions.values)
          if (tx.paymeTime >= from && tx.paymeTime <= to) tx.copy(),
      ]..sort((a, b) => a.paymeTime.compareTo(b.paymeTime));
}

/// In-memory [ClickBackend] for tests and demos. Not for production.
class InMemoryClickBackend implements ClickBackend {
  /// Orders by id, with their amount in tiyin.
  final Map<String, int> orders = {};
  final Map<String, ClickOrderStatus> status = {};
  final Map<int, ClickPrepare> prepares = {};
  var _seq = 0;

  @override
  Future<ClickOrder?> findOrder(String merchantTransId) async {
    final amount = orders[merchantTransId];
    if (amount == null) return null;
    return ClickOrder(
        id: merchantTransId, amountTiyin: amount, status: status[merchantTransId] ?? ClickOrderStatus.pending);
  }

  @override
  Future<int> prepare(ClickOrder order, ClickRequest request) async {
    for (final p in prepares.values) {
      if (p.clickTransId == request.clickTransId) return p.id;
    }
    final id = ++_seq;
    prepares[id] = ClickPrepare(id: id, orderId: order.id, clickTransId: request.clickTransId);
    return id;
  }

  @override
  Future<ClickPrepare?> findPrepare(int merchantPrepareId) async => prepares[merchantPrepareId];

  @override
  Future<int> complete(ClickOrder order, ClickPrepare prepare, ClickRequest request) async {
    status[order.id] = ClickOrderStatus.paid;
    return prepare.id;
  }

  @override
  Future<void> cancel(ClickOrder order, ClickPrepare prepare, ClickRequest request) async {
    status[order.id] = ClickOrderStatus.cancelled;
  }
}
