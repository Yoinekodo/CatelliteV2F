import winreg
import datetime
from cryptography.fernet import Fernet

def trial_set(path: str):
    if path == "":
        return

    key_name = "Expired_key"
    value_name = "Expire"

    try:
        key = winreg.OpenKeyEx(winreg.HKEY_CURRENT_USER, path)
        winreg.CloseKey(key)
    except FileNotFoundError:
        new_key = Fernet.generate_key()
        fernet = Fernet(new_key)

        expired_date = datetime.datetime.now() + datetime.timedelta(days=31)
        expired_str = expired_date.strftime('%Y-%m-%d')

        enc_data = fernet.encrypt(expired_str.encode('utf-8'))

        key = winreg.CreateKeyEx(
            winreg.HKEY_CURRENT_USER,
            path,
            access=winreg.KEY_WRITE
        )

        winreg.SetValueEx(key, key_name, 0, winreg.REG_BINARY, new_key)
        winreg.SetValueEx(key, value_name, 0, winreg.REG_BINARY, enc_data)
        winreg.CloseKey(key)

def get_expired(path):
    if path == "": ""
    key_name = "Expired_key"
    value_name = "Expire"
    unlimit_name = "SetUnlimit"
    now = datetime.datetime.now().strftime('%Y-%m-%d')
    try:
        key = winreg.OpenKeyEx(winreg.HKEY_CURRENT_USER, path)
        enc_key_data, _ = winreg.QueryValueEx(key, key_name)
        fernet = Fernet(enc_key_data)
        enc_data, _ = winreg.QueryValueEx(key, value_name)
        expired_str = fernet.decrypt(enc_data).decode('utf-8')
        winreg.CloseKey(key)

        delta = datetime.datetime.strptime(expired_str, '%Y-%m-%d') - datetime.datetime.strptime(now, '%Y-%m-%d')
    except FileNotFoundError:
        return ""

    try:
        key = winreg.OpenKeyEx(winreg.HKEY_CURRENT_USER, path)
        unlimit, _ = winreg.QueryValueEx(key, unlimit_name)
        winreg.CloseKey(key)

        if unlimit is not None:
            return "unlimit", 0
    except FileNotFoundError:
        pass

    return expired_str, delta.days
