export interface VmMessages extends Record<string, string> {
  title: string
  description: string
  name: string
  cpu: string
  memory_mib: string
  disk_gib: string
  copy: string
  exclusions: string
  unavailable: string
  retrySame: string
  retry: string
  create: string
  registered: string
  connect: string
  queued: string
  provisioning: string
  ready: string
  failed: string
  back: string
}

export const vmEn: VmMessages = {
  title: 'Create Linux VM',
  description:
    'A persistent isolated Linux installation on the main gateway. Creation continues after closing this dialog. Configure the model in the new gateway after it is ready.',
  name: 'Bot name',
  cpu: 'CPU cores',
  memory_mib: 'RAM (MiB)',
  disk_gib: 'Disk (GiB)',
  copy: 'Copy main provider API keys',
  exclusions:
    'Copies only listed provider API keys. OAuth logins, messaging identities and cluster credentials are excluded.',
  unavailable: 'Provisioning is unavailable. Connect to the configured main gateway and try again.',
  retrySame: 'Submission outcome is unknown. Retry sends the same request; it will not create a duplicate.',
  retry: 'Retry same request',
  create: 'Create VM',
  registered: 'Bot gateway added. Open it from the gateway list.',
  connect: 'Add gateway',
  queued: 'Queued',
  provisioning: 'Provisioning',
  ready: 'Ready',
  failed: 'Failed',
  back: 'Back'
}

export const vmJa: VmMessages = {
  title: 'Linux VM を作成',
  description:
    'メインゲートウェイ上に永続的で独立した Linux を作成します。閉じても処理は続きます。準備完了後にモデルを設定してください。',
  name: 'ボット名',
  cpu: 'CPU コア',
  memory_mib: 'RAM (MiB)',
  disk_gib: 'ディスク (GiB)',
  copy: 'メインの API キーをコピー',
  exclusions: '表示された API キーのみコピーします。OAuth、メッセージング ID、クラスター認証情報は対象外です。',
  unavailable: 'プロビジョニングを利用できません。設定済みのメインゲートウェイに接続してください。',
  retrySame: '送信結果が不明です。同じ要求を再試行しても重複作成しません。',
  retry: '同じ要求を再試行',
  create: 'VM を作成',
  registered: 'ゲートウェイを追加しました。一覧から開いてください。',
  connect: 'ゲートウェイを追加',
  queued: '待機中',
  provisioning: '作成中',
  ready: '準備完了',
  failed: '失敗',
  back: '戻る'
}

export const vmZh: VmMessages = {
  title: '创建 Linux 虚拟机',
  description: '在主网关上创建持久且隔离的 Linux 安装。关闭窗口后仍会继续。就绪后请配置模型。',
  name: '机器人名称',
  cpu: 'CPU 核心',
  memory_mib: '内存 (MiB)',
  disk_gib: '磁盘 (GiB)',
  copy: '复制主网关的 API 密钥',
  exclusions: '仅复制列出的 API 密钥，不包括 OAuth 登录、消息身份和集群凭据。',
  unavailable: '无法配置虚拟机。请连接已配置的主网关后重试。',
  retrySame: '提交结果未知。重试会发送同一请求，不会重复创建。',
  retry: '重试同一请求',
  create: '创建虚拟机',
  registered: '已添加机器人网关，请从网关列表打开。',
  connect: '添加网关',
  queued: '排队中',
  provisioning: '配置中',
  ready: '已就绪',
  failed: '失败',
  back: '返回'
}

export const vmZhHant: VmMessages = {
  title: '建立 Linux 虛擬機',
  description: '在主閘道上建立持久且隔離的 Linux 安裝。關閉視窗後仍會繼續。就緒後請設定模型。',
  name: '機器人名稱',
  cpu: 'CPU 核心',
  memory_mib: '記憶體 (MiB)',
  disk_gib: '磁碟 (GiB)',
  copy: '複製主閘道的 API 金鑰',
  exclusions: '僅複製列出的 API 金鑰，不包含 OAuth 登入、訊息身分和叢集憑證。',
  unavailable: '無法配置虛擬機。請連接已設定的主閘道後重試。',
  retrySame: '提交結果未知。重試會傳送同一要求，不會重複建立。',
  retry: '重試同一要求',
  create: '建立虛擬機',
  registered: '已加入機器人閘道，請從清單開啟。',
  connect: '加入閘道',
  queued: '排隊中',
  provisioning: '配置中',
  ready: '已就緒',
  failed: '失敗',
  back: '返回'
}
