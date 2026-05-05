# text2calendar 项目部署指南
=====================================

项目位置: ~/ws/text2calendar 或 /workspace/text2calendar

一、项目已创建完成！
---------------------------------------------------
✅ 项目已完整创建
✅ 包括所有核心功能:
   - 文字日程解析（纯规则，无需AI）
   - Google/Outlook/iCal 日历接口
   - REST API + 测试

二、部署到 GitHub 的方法
=====================================================

方法一: 在 GitHub 网页端上传（最简单）
-------------------------------------------------------------------
1. 访问 https://github.com/lvxin1024/text2calendar
2. 如果仓库不存在？
   - 在 GitHub 上点击 "New repository" 创建
   - 命名为 "text2calendar"，不要初始化 README
3. 点击 "Add file" -> "Upload files"
4. 将项目中所有文件上传
5. 提交后点击 "Commit changes"

方法二: 在本地推送到 GitHub（电脑端）
-------------------------------------------------------------------
在电脑端执行：

cd ~/ws/text2calendar  # 或者 cd /workspace/text2calendar

# 如果 Git 没有正确配置：
rm -rf .git
git init
git add .
git commit -m "Initial commit: text2calendar project"
git branch -M main
git remote add origin https://github.com/lvxin1024/text2calendar.git
git push -u origin main

三、项目使用说明
---------------------------------------------------
cd ~/ws/text2calendar  # 或者 cd /workspace/text2calendar
pip install -r requirements.txt

# 运行示例
python examples/simple_example.py

# 启动 API 服务
python -m src.main
