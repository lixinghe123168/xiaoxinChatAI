import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_theme.dart';
import '../providers/app_provider.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  String? _loginUrl;
  bool _isConnecting = false;
  Timer? _pollTimer;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPollLogin(AppProvider provider) {
    _pollTimer?.cancel();
    
    print('[MainPage] 开始轮询微信登录状态...');
    
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) {
        _pollTimer?.cancel();
        return;
      }

      if (provider.wechatStatus.isConnected) {
        print('[MainPage] 检测到已连接，停止轮询');
        _pollTimer?.cancel();
        setState(() => _isConnecting = false);
        return;
      }

      final qrcodeKey = provider.wechatStatus.qrcodeKey;
      if (qrcodeKey == null || qrcodeKey.isEmpty) {
        print('[MainPage] qrcodeKey 为空，跳过本次轮询');
        return;
      }

      try {
        print('[MainPage] 轮询第 ${_pollTimer?.tick ?? 0} 次, qrcodeKey: ${qrcodeKey.length > 20 ? "${qrcodeKey.substring(0, 20)}..." : qrcodeKey}');
        
        final status = await provider.pollWechatStatus();
        
        print('[MainPage] 轮询结果 - isConfirmed: ${status.isConfirmed}, isScanned: ${status.isScanned}, isExpired: ${status.isExpired}, message: "${status.message}"');
        
        if (status.isConfirmed) {
          print('[MainPage] 微信扫码确认，正在完成登录...');
          _pollTimer?.cancel();
          
          await provider.completeWechatLogin(status);
          
          if (mounted && provider.wechatStatus.isConnected) {
            setState(() => _isConnecting = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ 微信连接成功！'),
                behavior: SnackBarBehavior.floating,
                backgroundColor: AppTheme.successColor,
                duration: Duration(seconds: 4),
              ),
            );
          }
        } else if (status.isExpired) {
          print('[MainPage] 二维码已过期');
          _pollTimer?.cancel();
          if (mounted) {
            setState(() => _isConnecting = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('⏰ 二维码已过期，请重新连接'),
                behavior: SnackBarBehavior.floating,
                backgroundColor: AppTheme.errorColor,
              ),
            );
          }
        } else {
          print('[MainPage] 等待扫码... (${provider.wechatStatus.statusMessage})');
        }
      } catch (e) {
        print('[MainPage] 轮询异常: $e');
      }
    });
  }

  Future<void> _connectWechat(AppProvider provider) async {
    setState(() {
      _isConnecting = true;
      _loginUrl = null;
    });

    try {
      final url = await provider.getWechatQrCode();
      final uri = Uri.tryParse(url);

      if (uri != null && uri.scheme.startsWith('http')) {
        setState(() => _loginUrl = url);

        final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (opened && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已在浏览器中打开，请完成微信登录'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 4),
            ),
          );
        }
        _startPollLogin(provider);
      } else if (url.isNotEmpty) {
        setState(() => _loginUrl = url);
        _startPollLogin(provider);
      } else {
        if (mounted) {
          setState(() => _isConnecting = false);
          final errorMsg = provider.errorMessage ?? '未知错误';
          _showErrorDialog('获取链接失败', errorMsg);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConnecting = false);
        final errorDetail = e.toString().replaceAll('Exception: ', '');
        _showErrorDialog('连接失败', errorDetail);
      }
    }
  }

  void _showErrorDialog(String title, String error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              error,
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: error));
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('错误信息已复制'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: const Text('复制错误信息'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          backgroundColor: AppTheme.backgroundColor,
          appBar: AppBar(
            title: const Text('xiaoxinChatAI'),
          ),
          body: _buildBody(provider),
        );
      },
    );
  }

  Widget _buildBody(AppProvider provider) {
    final status = provider.wechatStatus;

    if (status.isConnected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppTheme.successColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_circle_rounded,
                size: 48,
                color: AppTheme.successColor,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '微信已连接',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            if (status.userId != null) ...[
              const SizedBox(height: 8),
              Text(
                '用户ID: ${status.userId}',
                style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 32),
            OutlinedButton.icon(
              onPressed: () => provider.disconnectWechat(),
              icon: const Icon(Icons.link_off_rounded, size: 18),
              label: const Text('断开连接'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.errorColor,
                side: const BorderSide(color: AppTheme.errorColor),
              ),
            ),
          ],
        ),
      );
    }

    if (_isConnecting) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: AppTheme.primaryColor.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '正在连接微信...',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                status.statusMessage ?? '请在浏览器中完成微信登录',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: AppTheme.textSecondary,
                ),
              ),
              if (_loginUrl != null) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.dividerColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.link_rounded, size: 16, color: AppTheme.textSecondary),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '登录链接',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        _loginUrl!,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary.withValues(alpha: 0.8),
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _loginUrl!));
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('链接已复制到剪贴板'),
                                  behavior: SnackBarBehavior.floating,
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: const Text('复制链接'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.wechat_rounded,
                size: 44,
                color: AppTheme.primaryColor.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '连接微信机器人',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '点击按钮将自动打开浏览器前往微信登录页面',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () => _connectWechat(provider),
              icon: const Icon(Icons.open_in_browser_rounded, size: 20),
              label: const Text('连接微信'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}