@echo off
REM Bootstrap — runs: irm ... | iex
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/khoazero123/ip-watch/master/install-ipv6-watch.ps1' | iex"
