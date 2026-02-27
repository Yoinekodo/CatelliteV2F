@echo off
echo Python 3.11 ポータブル環境を構築中...

echo Python 3.11のダウンロード中...
powershell -c "Invoke-WebRequest https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip -OutFile python-3.11.9-embed-amd64.zip"

echo Python 3.11の展開中...
REM 1. 展開
powershell -c "Expand-Archive -Path python-3.11.9-embed-amd64.zip -DestinationPath . -Force"

echo Python 3.11のpipを有効化中...
REM 2. pip有効化（_pth編集）
powershell -c "(Get-Content python311._pth) -replace '#import site', 'import site' | Set-Content python311._pth"

echo Python 3.11にpipをインストール中...
REM 3. pipインストール
powershell -c "./python.exe get-pip.py"