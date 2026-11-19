import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'zh-CN',
  title: 'Lite2D',
  description: '面向 Apple Silicon Mac 的菜单栏 Live2D 播放器。',
  base: '/Lite2D/',
  cleanUrls: true,
  head: [['link', { rel: 'icon', href: '/Lite2D/app-icon.png' }]],
  themeConfig: {
    logo: '/app-icon.png',
    nav: [
      { text: '快速开始', link: '/guide' },
      { text: '更新日志', link: '/changelog' }
    ],
    outline: { label: '本页内容', level: [2, 2] },
    socialLinks: [{ icon: 'github', link: 'https://github.com/0x535a/Lite2D' }],
    darkModeSwitchLabel: '主题',
    lightModeSwitchTitle: '切换到浅色主题',
    darkModeSwitchTitle: '切换到深色主题',
    returnToTopLabel: '返回顶部',
    sidebarMenuLabel: '菜单'
  }
})
