# rc522.py
import time
import re
from . import bus
import urllib.request
import urllib.parse
import json
import threading


class RC522:

    # ========== RC522 寄存器 ==========
    CommandReg = 0x01
    FIFODataReg = 0x09
    FIFOLevelReg = 0x0A
    ControlReg = 0x0C
    BitFramingReg = 0x0D
    ModeReg = 0x11
    TxControlReg = 0x14
    TxASKReg = 0x15
    TModeReg = 0x2A
    TPrescalerReg = 0x2B
    TReloadRegH = 0x2C
    TReloadRegL = 0x2D
    VersionReg = 0x37

    ComIrqReg = 0x04
    DivIrqReg = 0x05
    ErrorReg = 0x06
    PCD_Transceive = 0x0C

    CRCResultRegL = 0x22
    CRCResultRegH = 0x21
    PCD_CalcCRC = 0x03

    PCD_Idle = 0x00
    PCD_SoftReset = 0x0F

    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')

        address = config.getint('address', 40)
        speed = config.getint('speed', 100000)

        self.i2c = bus.MCU_I2C_from_config(config, address, speed)

        self.gcode.register_command("M410", self.cmd_read_rfid)
        self.printer.register_event_handler("klippy:ready", self._handle_ready)

        self.last_parsed_data = None   # 存储最近一次有效解析的数据（原始字符串）
        self.scan_timer = None
        self.scan_end_time = 0
        self.last_uid = None

        self.moonraker_host = config.get('moonraker_host', '127.0.0.1')
        self.moonraker_port = config.getint('moonraker_port', 7125)
        self.scan_extruder = 1  # 默认挤出机编号
        self.auto_save = False  # 默认不自动保存

    # ================= I2C =================

    def write_reg(self, reg, val):
        self.i2c.i2c_write([reg, val])

    def read_reg(self, reg):
        params = self.i2c.i2c_read([reg], 1)
        return params['response'][0]

    def set_bit_mask(self, reg, mask):
        tmp = self.read_reg(reg)
        self.write_reg(reg, tmp | mask)

    def clear_bit_mask(self, reg, mask):
        tmp = self.read_reg(reg)
        self.write_reg(reg, tmp & (~mask))

    # ================= 初始化 =================

    def _handle_ready(self):
        self.init_rc522()

    def init_rc522(self):

        self.write_reg(self.CommandReg, self.PCD_SoftReset)
        time.sleep(0.1)

        self.write_reg(self.TModeReg, 0x8D)
        self.write_reg(self.TPrescalerReg, 0x3E)
        self.write_reg(self.TReloadRegL, 30)
        self.write_reg(self.TReloadRegH, 0)

        self.write_reg(self.TxASKReg, 0x40)
        self.write_reg(self.ModeReg, 0x3D)

        self.antenna_on()

    def antenna_on(self):
        temp = self.read_reg(self.TxControlReg)
        if not (temp & 0x03):
            self.set_bit_mask(self.TxControlReg, 0x03)

    # ================= 通信核心 =================

    def transceive(self, send_data):

        self.write_reg(self.CommandReg, self.PCD_Idle)
        self.write_reg(self.ComIrqReg, 0x7F)
        self.write_reg(self.FIFOLevelReg, 0x80)

        for d in send_data:
            self.write_reg(self.FIFODataReg, d)

        self.write_reg(self.CommandReg, self.PCD_Transceive)
        self.set_bit_mask(self.BitFramingReg, 0x80)

        i = 2000
        while True:
            irq = self.read_reg(self.ComIrqReg)
            if irq & 0x20:
                break
            if irq & 0x01:
                return None
            i -= 1
            if i == 0:
                return None

        self.clear_bit_mask(self.BitFramingReg, 0x80)

        error = self.read_reg(self.ErrorReg)
        if error & 0x1B:
            return None

        length = self.read_reg(self.FIFOLevelReg)
        if length == 0:
            return None

        result = []
        for _ in range(length):
            result.append(self.read_reg(self.FIFODataReg))

        return result

    # ================= 卡片流程 =================

    def request(self):
        self.write_reg(self.BitFramingReg, 0x07)
        result = self.transceive([0x26])
        self.write_reg(self.BitFramingReg, 0x00)

        if result and len(result) == 2:
            return result
        return None

    def anticoll(self, cmd):
        self.write_reg(self.BitFramingReg, 0x00)
        return self.transceive([cmd, 0x20])

    def select(self, cmd, uid_block):

        buf = [cmd, 0x70] + uid_block[:5]
        crc = self.calculate_crc(buf)
        buf += crc

        return self.transceive(buf)

    def get_uid(self):

        cl1 = self.anticoll(0x93)
        if not cl1 or len(cl1) < 5:
            return None

        self.select(0x93, cl1)

        if cl1[0] == 0x88:

            uid_part1 = cl1[1:4]
            cl2 = self.anticoll(0x95)
            if not cl2 or len(cl2) < 5:
                return None

            self.select(0x95, cl2)
            uid_part2 = cl2[:4]

            return uid_part1 + uid_part2

        else:
            return cl1[:4]

    def calculate_crc(self, data):

        self.write_reg(self.CommandReg, self.PCD_Idle)
        self.write_reg(self.DivIrqReg, 0x04)
        self.write_reg(self.FIFOLevelReg, 0x80)

        for b in data:
            self.write_reg(self.FIFODataReg, b)

        self.write_reg(self.CommandReg, self.PCD_CalcCRC)

        for _ in range(1000):
            n = self.read_reg(self.DivIrqReg)
            if n & 0x04:
                break

        crcL = self.read_reg(self.CRCResultRegL)
        crcH = self.read_reg(self.CRCResultRegH)

        return [crcL, crcH]

    def read_page(self, page):

        self.write_reg(self.BitFramingReg, 0x00)

        buf = [0x30, page]
        crc = self.calculate_crc(buf)
        buf += crc

        result = self.transceive(buf)

        if result and len(result) >= 16:
            return result[:16]

        return None

    def read_all_user_pages(self):

        data = []

        for page in range(4, 40, 4):

            block = self.read_page(page)
            if not block:
                return None

            data += block

        return data

    def _scan_loop(self, eventtime):

        # 超时结束
        if eventtime >= self.scan_end_time:
            self.scan_timer = None
            self.gcode.respond_info("Scan finished (5s timeout)")
            return self.reactor.NEVER

        if not self.request():
            return eventtime + 0.1

        uid = self.get_uid()
        if not uid:
            return eventtime + 0.1

        # 去重
        if uid == self.last_uid:
            return eventtime + 0.1

        self.last_uid = uid

        all_data = self.read_all_user_pages()
        if not all_data:
            return eventtime + 0.1

        hex_str = " ".join(f"{b:02X}" for b in all_data)

        ascii_str = ""
        for b in all_data:
            if 32 <= b <= 126:
                ascii_str += chr(b)
            else:
                ascii_str += "."

        # self.gcode.respond_info("USER DATA HEX: " + hex_str)
        # self.gcode.respond_info("USER DATA ASCII: " + ascii_str)

        # 解析出以 ';' 开始和 ';' 结束的数据部分
        parsed_data = self.extract_data(ascii_str)

        if parsed_data != "No valid data found":
            self.gcode.respond_info(f"PARSED DATA: {parsed_data}")
            self.last_parsed_data = parsed_data

            # 如果开启了自动保存，则解析并保存
            if self.auto_save:
                parsed_dict = self.parse_rfid_string(parsed_data, self.scan_extruder)
                if parsed_dict is not None:
                    self._save_parsed_to_moonraker(parsed_dict, self.scan_extruder)
                else:
                    self.gcode.respond_info("Failed to parse RFID data, not saving.")

            # 停止扫描
            self.reactor.unregister_timer(self.scan_timer)
            self.scan_timer = None
            self.gcode.respond_info("Scan stopped (valid data found)")
            return self.reactor.NEVER
        else:
            # 未解析到有效数据，继续扫描
            return eventtime + 0.1


    def extract_data(self, ascii_str):
        # 查找 "en{" 的位置
        marker = "en~"
        pos = ascii_str.find(marker)
        if pos == -1:
            return "No valid data found"
        # 从 "en{" 开始提取
        start = pos + 2
        # 查找最后一个}
        end = ascii_str.rfind('~')
        if end == -1 or end <= start:
            return "No valid data found"
        # 返回从 start 到 end+1 的子串（包含最后的}）
        return ascii_str[start:end+1]


    def parse_rfid_string(self, data_str, extruder=1):
        """
        解析形如 '{厂商;材料;子类;颜色;透明度;最低温;最高温;热床温;直径;重量;生产日期}' 的字符串
        示例: "~ERYONE-PA--FF00FF-FF-190-230-60-175-1000-2602~"
        返回解析后的字典。
        """
        if not data_str.startswith('~'):
            return None
        parts = data_str[1:].split('-')
        if len(parts) < 11:
            return None
        manufacturer = parts[0].strip()
        material_name = parts[1].strip()
        material_supplement = parts[2].strip() if parts[2].strip() else ""
        color_hex = parts[3].strip()
        transparency_str = parts[4].strip()
        min_temp_str = parts[5].strip()
        max_temp_str = parts[6].strip()
        bed_temp_str = parts[7].strip()
        diameter_str = parts[8].strip()
        weight_str = parts[9].strip()
        prod_date_str = parts[10].strip()

        # 转换颜色
        try:
            if not color_hex.startswith('#'):
                color_hex = '#' + color_hex
            r = int(color_hex[1:3], 16)
            g = int(color_hex[3:5], 16)
            b = int(color_hex[5:7], 16)
            color_rgb = [r, g, b]
        except:
            color_rgb = [128, 128, 128]
            color_hex = "#808080"

        try:
            transparency = int(transparency_str, 16) if transparency_str else 255
        except:
            transparency = 255

        try:
            min_temp = int(min_temp_str) if min_temp_str else 0
        except:
            min_temp = 0
        try:
            max_temp = int(max_temp_str) if max_temp_str else 0
        except:
            max_temp = 0
        try:
            bed_temp = int(bed_temp_str) if bed_temp_str else 0
        except:
            bed_temp = 0
        try:
            # 直径可能是整数，除以100得到mm
            diameter = float(diameter_str) / 100.0 if diameter_str else 1.75
        except:
            diameter = 1.75
        try:
            weight = int(weight_str) if weight_str else 0
        except:
            weight = 0
        try:
            prod_date = int(prod_date_str) if prod_date_str else 0
        except:
            prod_date = 0

        return {
            'manufacturer': manufacturer,
            'material_name': material_name,
            'material_supplement': material_supplement,
            'color_hex': color_hex,
            'color_rgb': color_rgb,
            'transparency': transparency,
            'min_temp': min_temp,
            'max_temp': max_temp,
            'bed_temp': bed_temp,
            'diameter': diameter,
            'weight': weight,
            'production_date': prod_date,
            'date_string': str(prod_date) if prod_date else '',
            'extruder': extruder
        }

    # ================= 保存到 Moonraker (后台线程) =================
    def _save_parsed_to_moonraker(self, parsed_dict, extruder):
        """在后台线程中保存解析后的字典到 Moonraker"""
        def do_save():
            url = f"http://{self.moonraker_host}:{self.moonraker_port}/server/database/item"
            key = f"extruder_{extruder}"
            payload = {
                "namespace": "rfid_tags",
                "key": key,
                "value": parsed_dict
            }
            try:
                data = json.dumps(payload).encode('utf-8')
                req = urllib.request.Request(url, data=data, method='POST')
                req.add_header('Content-Type', 'application/json')
                with urllib.request.urlopen(req, timeout=5) as response:
                    if response.getcode() == 200:
                        self.gcode.respond_info(f"RFID data saved to {key}")
                    else:
                        self.gcode.respond_info(f"Save failed: HTTP {response.getcode()}")
            except Exception as e:
                self.gcode.respond_info(f"Save error: {str(e)}")

        thread = threading.Thread(target=do_save)
        thread.daemon = True
        thread.start()

    # ================= GCODE ================= 

    def cmd_read_rfid(self, gcmd):
        """M410 命令：启动 RFID 扫描
           可选参数：
           EXTRUDER=<int>   : 挤出机编号，默认为 1
           SAVE=<0/1>       : 是否自动保存，默认为 0（不保存）
        """
        if self.scan_timer:
            self.gcode.respond_info("ERROR: Scan already running")
            return

        extruder_str = gcmd.get('EXTRUDER', '1')
        match = re.search(r'\d+', extruder_str)
        if match:
            extruder = int(match.group())
        else:
            extruder = 1
            self.gcode.respond_info(f"Invalid EXTRUDER value '{extruder_str}', using default 1")

        save_str = gcmd.get('SAVE', '0')
        match = re.search(r'\d+', save_str)
        if match:
            save = int(match.group()) == 1
        else:
            save = False
            self.gcode.respond_info(f"Invalid SAVE value '{save_str}', using default (no save)")

        self.scan_extruder = extruder
        self.auto_save = save
        self.last_uid = None
        self.scan_end_time = self.reactor.monotonic() + 5.0

        self.scan_timer = self.reactor.register_timer(
            self._scan_loop,
            self.reactor.monotonic()
        )
        


def load_config(config):
    return RC522(config)

def load_config_prefix(config):
    return RC522(config)