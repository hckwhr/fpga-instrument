package cn.xingzhewujiang.mineradio;

import android.app.*;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.os.*;
import android.widget.*;
import java.util.*;
import org.json.*;

@SuppressWarnings("deprecation")
final class BleCentral {
    private final MainActivity activity;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic writer;
    private BluetoothLeScanner scanner;
    private String connectId, writeId;
    private String sessionId;
    private UUID service, writeUuid, notifyUuid;
    private byte[] outgoing;
    private int offset;
    private boolean noResponse;
    private AlertDialog dialog;
    private Runnable deadline;
    private final List<BluetoothDevice> devices = new ArrayList<>();
    private ArrayAdapter<String> adapter;
    BleCentral(MainActivity activity) { this.activity = activity; }
    void connect(String id, JSONObject config) {
        if (connectId != null || gatt != null) { activity.failure(id, "已有 BLE 会话，请先断开"); return; }
        try {
            sessionId = config.getString("sessionId");
            service = UUID.fromString(config.optString("serviceUuid", "6e400001-b5a3-f393-e0a9-e50e24dcca9e"));
            writeUuid = UUID.fromString(config.optString("writeUuid", "6e400002-b5a3-f393-e0a9-e50e24dcca9e"));
            notifyUuid = UUID.fromString(config.optString("notifyUuid", "6e400003-b5a3-f393-e0a9-e50e24dcca9e"));
            BluetoothManager manager = activity.getSystemService(BluetoothManager.class);
            if (manager == null || manager.getAdapter() == null || !manager.getAdapter().isEnabled()) throw new IllegalStateException("请先开启手机蓝牙");
            scanner = manager.getAdapter().getBluetoothLeScanner();
            connectId = id; devices.clear(); adapter = new ArrayAdapter<>(activity, android.R.layout.simple_list_item_1);
            dialog = new AlertDialog.Builder(activity).setTitle("选择行者无疆 BLE 设备")
                .setAdapter(adapter, (d, index) -> {
                    scanner.stopScan(scanCallback); handler.removeCallbacksAndMessages(null);
                    gatt = devices.get(index).connectGatt(activity, false, callback, BluetoothDevice.TRANSPORT_LE);
                    timeout(20000, "BLE 连接或通知订阅超时");
                }).setNegativeButton("取消", (d, which) -> fail("已取消连接"))
                .setOnCancelListener(d -> fail("已取消连接")).create();
            dialog.show();
            scanner.startScan(Collections.singletonList(new ScanFilter.Builder().setServiceUuid(new ParcelUuid(service)).build()),
                new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback);
            timeout(15000, "未选择设备；请确认行者无疆已开机、未被其他设备占用，并检查蓝牙权限");
        } catch (Exception e) { if (connectId == null) activity.failure(id, e.getMessage()); else fail(e.getMessage()); }
    }
    private final ScanCallback scanCallback = new ScanCallback() {
        public void onScanResult(int type, ScanResult result) { handler.post(() -> {
            if (connectId == null || gatt != null || devices.contains(result.getDevice())) return;
            BluetoothDevice device = result.getDevice(); devices.add(device);
            String name = result.getScanRecord() == null ? null : result.getScanRecord().getDeviceName();
            adapter.add((name == null ? "未命名 BLE" : name) + "\n" + device.getAddress());
        }); }
        public void onScanFailed(int code) { handler.post(() -> fail("BLE 扫描失败：" + code)); }
    };
    private final BluetoothGattCallback callback = new BluetoothGattCallback() {
        public void onConnectionStateChange(BluetoothGatt g, int status, int state) { handler.post(() -> {
            if (g != gatt) { g.close(); return; }
            if (status != BluetoothGatt.GATT_SUCCESS || state == BluetoothProfile.STATE_DISCONNECTED) { fail("BLE 连接已断开（" + status + "）"); return; }
            if (state == BluetoothProfile.STATE_CONNECTED && !g.discoverServices()) fail("无法发现 BLE 服务");
        }); }
        public void onServicesDiscovered(BluetoothGatt g, int status) { handler.post(() -> {
            if (g != gatt) return;
            try {
                if (status != BluetoothGatt.GATT_SUCCESS) throw new IllegalStateException("服务发现失败");
                BluetoothGattService s = g.getService(service);
                if (s == null) throw new IllegalStateException("设备不含曲谱 BLE 服务");
                writer = s.getCharacteristic(writeUuid);
                BluetoothGattCharacteristic receiver = s.getCharacteristic(notifyUuid);
                if (writer == null || receiver == null) throw new IllegalStateException("BLE 特征不完整");
                int props = writer.getProperties();
                if ((props & (BluetoothGattCharacteristic.PROPERTY_WRITE | BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE)) == 0) throw new IllegalStateException("BLE 特征不可写");
                noResponse = (props & BluetoothGattCharacteristic.PROPERTY_WRITE) == 0;
                if (!g.setCharacteristicNotification(receiver, true)) throw new IllegalStateException("无法开启 BLE 通知");
                BluetoothGattDescriptor cccd = receiver.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"));
                if (cccd == null) throw new IllegalStateException("设备缺少通知描述符");
                cccd.setValue((receiver.getProperties() & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0 ? BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE : BluetoothGattDescriptor.ENABLE_INDICATION_VALUE);
                if (!g.writeDescriptor(cccd)) throw new IllegalStateException("BLE 通知订阅未开始");
            } catch (Exception e) { fail(e.getMessage()); }
        }); }
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor descriptor, int status) { handler.post(() -> {
            if (g != gatt || connectId == null) return;
            if (status != BluetoothGatt.GATT_SUCCESS) { fail("BLE 通知订阅失败：" + status); return; }
            clearTimeout(); String id = connectId; connectId = null;
            activity.success(id, object("name", g.getDevice().getName() == null ? "行者无疆" : g.getDevice().getName()));
        }); }
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic characteristic) {
            byte[] value = characteristic.getValue();
            if (value != null) notifyData(g, characteristic, value.clone());
        }
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic characteristic, byte[] value) {
            notifyData(g, characteristic, value.clone());
        }
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) { handler.post(() -> {
            if (g != gatt || writeId == null || noResponse) return;
            if (status != BluetoothGatt.GATT_SUCCESS) { fail("BLE 写入失败：" + status); return; }
            nextChunk();
        }); }
    };
    private void notifyData(BluetoothGatt g, BluetoothGattCharacteristic characteristic, byte[] bytes) {
        handler.post(() -> { if (g == gatt && characteristic.getUuid().equals(notifyUuid)) activity.event(object("type", "ble-data", "sessionId", sessionId, "data", android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP))); });
    }
    void write(String id, byte[] bytes) {
        if (gatt == null || writer == null || connectId != null) { activity.failure(id, "BLE 尚未就绪"); return; }
        if (writeId != null) { activity.failure(id, "上一笔 BLE 写入尚未完成"); return; }
        if (bytes.length == 0 || bytes.length > 4096) { activity.failure(id, "发送长度须为 1..4096 字节"); return; }
        outgoing = bytes; offset = 0; writeId = id; timeout(12000, "BLE 写入超时"); nextChunk();
    }
    private void nextChunk() {
        if (writeId == null) return;
        if (offset == outgoing.length) { clearTimeout(); String id = writeId; writeId = null; outgoing = null; activity.success(id, object("written", offset)); return; }
        int end = Math.min(offset + 20, outgoing.length);
        writer.setWriteType(noResponse ? BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE : BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
        writer.setValue(Arrays.copyOfRange(outgoing, offset, end));
        if (!gatt.writeCharacteristic(writer)) { fail("BLE 写入被系统拒绝"); return; }
        offset = end;
        // NO_RESPONSE only confirms local submission; FPGA ACK remains mandatory
        // in ScoreUploadSession. Pace chunks to avoid overflowing the radio queue.
        if (noResponse) handler.postDelayed(this::nextChunk, 25);
    }
    private void timeout(int ms, String message) { clearTimeout(); deadline = () -> fail(message); handler.postDelayed(deadline, ms); }
    private void clearTimeout() { if (deadline != null) handler.removeCallbacks(deadline); deadline = null; }
    private void fail(String message) {
        String failedSession = sessionId;
        String connecting = connectId, writing = writeId; connectId = null; writeId = null;
        close(); if (connecting != null) activity.failure(connecting, message); if (writing != null) activity.failure(writing, message);
        activity.event(object("type", "ble-disconnected", "sessionId", failedSession, "message", message));
    }
    void close() {
        clearTimeout(); handler.removeCallbacksAndMessages(null);
        if (scanner != null) { try { scanner.stopScan(scanCallback); } catch (Exception ignored) {} scanner = null; }
        if (dialog != null) { dialog.dismiss(); dialog = null; }
        if (gatt != null) { BluetoothGatt old = gatt; gatt = null; old.disconnect(); old.close(); }
        writer = null; outgoing = null;
        if (connectId != null) activity.failure(connectId, "已断开 BLE");
        if (writeId != null) activity.failure(writeId, "已断开 BLE，写入未完成");
        connectId = null; writeId = null;
    }
    static JSONObject object(Object... items) {
        JSONObject obj = new JSONObject();
        try { for (int i = 0; i < items.length; i += 2) obj.put((String)items[i], items[i + 1]); } catch (JSONException e) { throw new IllegalArgumentException(e); }
        return obj;
    }
}
