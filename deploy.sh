#!/bin/bash
# text2calendar 一键部署脚本

echo "======================================="
echo " text2calendar GitHub 部署工具"
echo "======================================="

PROJECT_DIR=$(dirname "$0")
cd "$PROJECT_DIR"

echo ""
echo "项目位置: $(pwd)"
echo ""

# 方法1: 网页版上传说明
echo "方法一: GitHub 网页端上传（推荐）"
echo "  1. 访问 https://github.com/lvxin1024/text2calendar"
echo "  2. 点击 Add file -> Upload files"
echo "  3. 上传所有项目文件"
echo ""

# 方法2: 本地推送
echo "方法二: 本地推送到 GitHub"
read -p "是否尝试本地推送？ (y/n) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "配置 Git..."

    # 配置用户信息
    git config user.name "lvxin1024"
    git config user.email "user@example.com"

    # 重置远程
    git remote rm origin
    git remote add origin https://github.com/lvxin1024/text2calendar.git

    echo ""
    echo "准备推送..."
    echo "请确保仓库已创建，然后输入你的 Personal Access Token"
    echo "或者按 Ctrl+C 停止"
    echo ""

    # 等待用户继续
    read -p "按 Enter 继续... "

    # 尝试推送
    git push -u origin main
fi

echo ""
echo "======================================="
echo "完成！访问 https://github.com/lvxin1024/text2calendar"
echo "======================================="
