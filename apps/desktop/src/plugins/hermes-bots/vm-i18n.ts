export interface VmMessages extends Record<string, string> {
  deleteTitle: string
  deleteDescription: string
  deleteAction: string
  retryDelete: string
  deleteUnavailable: string
  deleteLookupFailed: string
  deleteRetrySame: string
  deleteFailed: string
  deleting: string
  deleted: string
  delete_failed: string
  close: string
  nameRequired: string
  invalidUsername: string
  passwordRequired: string
  passwordInvalid: string
  passwordLength: string
  confirmationRequired: string
  resourceBounds: string
  checkingOwner: string
  ownerUnavailable: string
  lookupFailed: string
  submitting: string
  reservedUsername: string
  resumePassword: string
  loginUnavailable: string
  loginRules: string
  username: string
  password: string
  confirmPassword: string
  passwordMismatch: string
  loginDescription: string
  createProfile: string
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
  storageFailed: string
  recover: string
  recoverConfirm: string
  remoteTitle: string
  controlUnavailable: string
  connecting: string
  start: string
  stop: string
  restart: string
  refresh: string
  resources: string
  running: string
  starting: string
  stopping: string
  stopped: string
  unknown: string
  screen: string
  terminal: string
  connected: string
  disconnected: string
  superseded: string
  exited: string
  terminalUnavailable: string
  reconnect: string
  persistent: string
  powerUnknown: string
  retryPower: string
  connectionFailed: string
  powerConfirm: string
  operation: string
  operation_queued: string
  operation_dispatching: string
  operation_accepted: string
  operation_unknown: string
  operation_failed: string
}

export const vmEn: VmMessages = {
  deleteTitle: 'Delete {name} and its VM?',
  deleteDescription:
    'This stops {name} and removes its VM, workspace and files. This cannot be undone. Existing backups are retained.',
  deleteAction: 'Delete bot and VM',
  retryDelete: 'Retry deletion',
  deleteUnavailable: 'VM deletion is unavailable. Update or reconnect to the owning main gateway.',
  deleteLookupFailed: 'Cannot check the deletion request. Close and reopen this dialog to recover its status.',
  deleteRetrySame: 'Deletion outcome is unknown. Retry checks the saved operation before sending the same request.',
  deleteFailed: 'VM deletion failed. The bot remains registered.',
  deleting: 'Deleting VM and files…',
  deleted: 'VM and files deleted.',
  delete_failed: 'VM deletion failed',
  close: 'Close',
  nameRequired: 'Enter a bot name.',
  invalidUsername: 'Use 1–32 lowercase ASCII letters, numbers, underscores or hyphens. Start with a letter.',
  passwordRequired: 'Enter a VM password.',
  passwordInvalid: 'The VM password cannot contain NUL or line breaks.',
  passwordLength: 'Use {min}–{max} UTF-8 bytes for the VM password.',
  confirmationRequired: 'Confirm the VM password.',
  resourceBounds: '{resource} must be a whole number from {min} to {max}.',
  checkingOwner: 'Checking the owning main gateway…',
  ownerUnavailable: 'Cannot verify the owning main gateway. Close Create Bot, select the main gateway, then reopen it.',
  lookupFailed: 'Cannot check the saved request. Retry its lookup before submitting again.',
  submitting: 'Submitting the request…',
  reservedUsername: 'This Linux username is reserved. Choose another bot name.',
  resumePassword: 'The request was not found. Reenter the same VM password to retry this request.',
  loginUnavailable: 'VM login setup is unavailable. Update the main gateway before creating a bot.',
  loginRules:
    'Use 1–32 lowercase ASCII letters, numbers, underscores or hyphens. Start with a letter. Choose an 8–256 byte password without line breaks.',
  username: 'Linux username',
  password: 'VM password',
  confirmPassword: 'Confirm VM password',
  passwordMismatch: 'The passwords do not match.',
  loginDescription:
    'The Linux username is the bot name. This password signs in to the VM; it is separate from the controller login.',
  createProfile: 'Create a profile on an existing gateway',
  storageFailed: 'Unable to save the operation for safe retry. No command was sent.',
  recover: 'Review VM state',
  recoverConfirm:
    'Refresh the VM state and acknowledge the unknown command outcome. A later power action is a new command and may interrupt work.',
  remoteTitle: 'Remote VM',
  controlUnavailable: 'VM controls are unavailable for this gateway.',
  connecting: 'Connecting…',
  start: 'Start',
  stop: 'Stop',
  restart: 'Restart',
  refresh: 'Refresh',
  resources: 'Resources',
  running: 'Running',
  starting: 'Starting',
  stopping: 'Stopping',
  stopped: 'Stopped',
  unknown: 'Unknown',
  screen: 'Screen',
  terminal: 'Terminal',
  connected: 'Connected',
  disconnected: 'Disconnected. Reconnect to resume the shell.',
  superseded: 'Terminal control moved to another client. Reconnect to take control.',
  exited: 'The shell exited. Reconnect to open a new shell.',
  terminalUnavailable: 'The guest terminal is unavailable. Update the guest runtime and check tmux.',
  reconnect: 'Reconnect',
  persistent: 'Closing this pane leaves the VM, desktop and shell running.',
  powerUnknown: 'The command outcome is unknown. Retry uses the same operation ID and cannot send another restart.',
  retryPower: 'Retry same operation',
  connectionFailed: 'Unable to reach the selected VM or its main gateway. Refresh to try again.',
  powerConfirm: 'This interrupts work in this VM. Its disk and files are preserved.',
  operation: 'Power command',
  operation_queued: 'Queued',
  operation_dispatching: 'Sending',
  operation_accepted: 'Accepted; waiting for VM state',
  operation_unknown: 'Outcome unknown. Refresh VM state before another action.',
  operation_failed: 'Failed',
  title: 'Create Linux VM',
  description:
    'A persistent isolated Linux installation on the main gateway. Creation continues after closing this dialog. Configure the model in the new gateway after it is ready.',
  name: 'Bot name',
  cpu: 'CPU cores',
  memory_mib: 'RAM (MiB)',
  disk_gib: 'Disk (GiB)',
  copy: 'Copy main provider API keys',
  exclusions:
    'Copies only listed provider API keys. Model settings are separate. Codex requires sign-in on each bot. OAuth logins, messaging identities and cluster credentials are excluded.',
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
  deleteTitle: '{name} と VM を削除しますか？',
  deleteDescription:
    '{name} を停止し、VM、作業領域、ファイルを削除します。元に戻せません。既存のバックアップは保持されます。',
  deleteAction: 'ボットと VM を削除',
  retryDelete: '削除を再試行',
  deleteUnavailable: 'VM を削除できません。所有元のメインゲートウェイを更新するか再接続してください。',
  deleteLookupFailed: '削除状態を確認できません。この画面を閉じて開き直してください。',
  deleteRetrySame: '削除結果が不明です。再試行時は保存済みの操作を確認し、同じ要求を送ります。',
  deleteFailed: 'VM の削除に失敗しました。ボットの登録は残っています。',
  deleting: 'VM とファイルを削除中…',
  deleted: 'VM とファイルを削除しました。',
  delete_failed: 'VM の削除に失敗',
  close: '閉じる',
  nameRequired: 'ボット名を入力してください。',
  invalidUsername: '名前は小文字の英字で始まる 1～32 文字の英数字・_・- です。',
  passwordRequired: 'VM のパスワードを入力してください。',
  passwordInvalid: 'VM のパスワードに NUL や改行は使用できません。',
  passwordLength: 'VM のパスワードは UTF-8 で {min}～{max} バイトです。',
  confirmationRequired: 'VM のパスワードを確認してください。',
  resourceBounds: '{resource} は {min}～{max} の整数にしてください。',
  checkingOwner: '所有元のメインゲートウェイを確認中…',
  ownerUnavailable: '所有元を確認できません。作成画面を閉じ、メインゲートウェイを選択して開き直してください。',
  lookupFailed: '保存済みの要求を確認できません。送信前に再度確認してください。',
  submitting: '要求を送信中…',
  reservedUsername: 'この Linux ユーザー名は予約済みです。別のボット名を選択してください。',
  resumePassword: '要求が見つかりません。同じ VM パスワードを再入力して再試行してください。',
  loginUnavailable: 'VM のログイン設定を利用できません。ボットを作成する前にメインゲートウェイを更新してください。',
  loginRules: '名前は小文字の英字で始まる 1～32 文字の英数字・_・- です。パスワードは改行なしの 8～256 バイトです。',
  username: 'Linux ユーザー名',
  password: 'VM のパスワード',
  confirmPassword: 'VM のパスワードを確認',
  passwordMismatch: 'パスワードが一致しません。',
  loginDescription: 'Linux ユーザー名はボット名です。このパスワードは VM 用で、コントローラーへのログインとは別です。',
  createProfile: '既存のゲートウェイにプロファイルを作成',
  storageFailed: '安全な再試行用に操作を保存できません。コマンドは送信されていません。',
  recover: 'VM の状態を確認',
  recoverConfirm: 'VM の状態を更新し、結果不明の操作を確認します。次の電源操作は新しいコマンドです。',
  remoteTitle: 'リモート VM',
  controlUnavailable: 'このゲートウェイでは VM 操作を利用できません。',
  connecting: '接続中…',
  start: '起動',
  stop: '停止',
  restart: '再起動',
  refresh: '更新',
  resources: 'リソース',
  running: '実行中',
  starting: '起動中',
  stopping: '停止中',
  stopped: '停止済み',
  unknown: '不明',
  screen: '画面',
  terminal: 'ターミナル',
  connected: '接続済み',
  disconnected: '切断されました。再接続してシェルを再開してください。',
  superseded: '別のクライアントが操作中です。再接続すると操作を引き継ぎます。',
  exited: 'シェルが終了しました。再接続すると新しいシェルを開きます。',
  terminalUnavailable: 'ゲストのターミナルを利用できません。ランタイムと tmux を確認してください。',
  reconnect: '再接続',
  persistent: '閉じても VM、デスクトップ、シェルは動作を続けます。',
  powerUnknown: '操作結果が不明です。同じ操作 ID で再試行しても再起動は重複しません。',
  retryPower: '同じ操作を再試行',
  connectionFailed: '選択した VM またはメインゲートウェイに接続できません。更新してください。',
  powerConfirm: 'この VM の作業を中断します。ディスクとファイルは保持されます。',
  operation: '電源操作',
  operation_queued: '待機中',
  operation_dispatching: '送信中',
  operation_accepted: '受付済み。VM の状態を確認中',
  operation_unknown: '結果が不明です。次の操作の前に VM の状態を更新してください。',
  operation_failed: '失敗',
  title: 'Linux VM を作成',
  description:
    'メインゲートウェイ上に永続的で独立した Linux を作成します。閉じても処理は続きます。準備完了後にモデルを設定してください。',
  name: 'ボット名',
  cpu: 'CPU コア',
  memory_mib: 'RAM (MiB)',
  disk_gib: 'ディスク (GiB)',
  copy: 'メインのプロバイダー API キーをコピー',
  exclusions:
    '表示されたプロバイダー API キーのみコピーします。モデル設定は別です。Codex はボットごとにサインインが必要です。OAuth、メッセージング ID、クラスター認証情報は対象外です。',
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
  deleteTitle: '删除 {name} 及其虚拟机？',
  deleteDescription: '这将停止 {name} 并删除其虚拟机、工作区和文件。此操作无法撤销。现有备份将保留。',
  deleteAction: '删除机器人和虚拟机',
  retryDelete: '重试删除',
  deleteUnavailable: '虚拟机删除不可用。请更新或重新连接所属主网关。',
  deleteLookupFailed: '无法查询删除状态。请关闭并重新打开此窗口。',
  deleteRetrySame: '删除结果未知。重试会先查询已保存的操作，再发送同一请求。',
  deleteFailed: '虚拟机删除失败。机器人仍保留注册。',
  deleting: '正在删除虚拟机和文件…',
  deleted: '虚拟机和文件已删除。',
  delete_failed: '虚拟机删除失败',
  close: '关闭',
  nameRequired: '请输入机器人名称。',
  invalidUsername: '名称须以小写英文字母开头，长度为 1–32 个英文字母、数字、下划线或连字符。',
  passwordRequired: '请输入虚拟机密码。',
  passwordInvalid: '虚拟机密码不能包含 NUL 或换行符。',
  passwordLength: '虚拟机密码须为 {min}–{max} 个 UTF-8 字节。',
  confirmationRequired: '请确认虚拟机密码。',
  resourceBounds: '{resource} 须为 {min} 到 {max} 之间的整数。',
  checkingOwner: '正在检查所属主网关…',
  ownerUnavailable: '无法验证所属主网关。请关闭创建窗口，选择主网关后重新打开。',
  lookupFailed: '无法查询已保存的请求。再次提交前请重试查询。',
  submitting: '正在提交请求…',
  reservedUsername: '此 Linux 用户名已保留。请选择其他机器人名称。',
  resumePassword: '未找到请求。请重新输入相同的虚拟机密码后重试此请求。',
  loginUnavailable: '虚拟机登录设置不可用。请先更新主网关，再创建机器人。',
  loginRules:
    '名称须以小写英文字母开头，包含 1–32 个小写英文字母、数字、下划线或连字符。密码须为 8–256 字节且不含换行。',
  username: 'Linux 用户名',
  password: '虚拟机密码',
  confirmPassword: '确认虚拟机密码',
  passwordMismatch: '两次输入的密码不一致。',
  loginDescription: 'Linux 用户名与机器人名称相同。此密码用于登录虚拟机，与控制器登录不同。',
  createProfile: '在现有网关上创建配置文件',
  storageFailed: '无法保存操作以安全重试。未发送命令。',
  recover: '检查虚拟机状态',
  recoverConfirm: '刷新状态并确认命令结果未知。之后的电源操作将是新命令，可能中断工作。',
  remoteTitle: '远程虚拟机',
  controlUnavailable: '此网关不支持虚拟机控制。',
  connecting: '连接中…',
  start: '启动',
  stop: '停止',
  restart: '重启',
  refresh: '刷新',
  resources: '资源',
  running: '运行中',
  starting: '启动中',
  stopping: '停止中',
  stopped: '已停止',
  unknown: '未知',
  screen: '屏幕',
  terminal: '终端',
  connected: '已连接',
  disconnected: '连接已断开。重新连接可恢复会话。',
  superseded: '另一客户端已接管终端。重新连接可接管控制。',
  exited: 'Shell 已退出。重新连接将打开新 Shell。',
  terminalUnavailable: '访客终端不可用。请更新运行环境并检查 tmux。',
  reconnect: '重新连接',
  persistent: '关闭此面板后，虚拟机、桌面和 Shell 会继续运行。',
  powerUnknown: '命令结果未知。重试使用相同操作 ID，不会重复重启。',
  retryPower: '重试同一操作',
  connectionFailed: '无法连接所选虚拟机或主网关，请刷新重试。',
  powerConfirm: '此操作会中断该虚拟机中的工作。磁盘和文件会保留。',
  operation: '电源命令',
  operation_queued: '排队中',
  operation_dispatching: '发送中',
  operation_accepted: '已接受，等待虚拟机状态',
  operation_unknown: '结果未知。执行下一操作前请刷新虚拟机状态。',
  operation_failed: '失败',
  title: '创建 Linux 虚拟机',
  description: '在主网关上创建持久且隔离的 Linux 安装。关闭窗口后仍会继续。就绪后请配置模型。',
  name: '机器人名称',
  cpu: 'CPU 核心',
  memory_mib: '内存 (MiB)',
  disk_gib: '磁盘 (GiB)',
  copy: '复制主网关的提供商 API 密钥',
  exclusions:
    '仅复制列出的提供商 API 密钥。模型设置独立。每个机器人都需要单独登录 Codex。不包括 OAuth 登录、消息身份和集群凭据。',
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
  deleteTitle: '刪除 {name} 及其虛擬機？',
  deleteDescription: '這將停止 {name} 並刪除其虛擬機、工作區和檔案。此操作無法復原。現有備份將保留。',
  deleteAction: '刪除機器人和虛擬機',
  retryDelete: '重試刪除',
  deleteUnavailable: '虛擬機刪除無法使用。請更新或重新連接所屬主閘道。',
  deleteLookupFailed: '無法查詢刪除狀態。請關閉並重新開啟此視窗。',
  deleteRetrySame: '刪除結果未知。重試會先查詢已儲存的操作，再傳送同一請求。',
  deleteFailed: '虛擬機刪除失敗。機器人仍保留註冊。',
  deleting: '正在刪除虛擬機和檔案…',
  deleted: '虛擬機和檔案已刪除。',
  delete_failed: '虛擬機刪除失敗',
  close: '關閉',
  nameRequired: '請輸入機器人名稱。',
  invalidUsername: '名稱須以小寫英文字母開頭，長度為 1–32 個英文字母、數字、底線或連字號。',
  passwordRequired: '請輸入虛擬機密碼。',
  passwordInvalid: '虛擬機密碼不能包含 NUL 或換行字元。',
  passwordLength: '虛擬機密碼須為 {min}–{max} 個 UTF-8 位元組。',
  confirmationRequired: '請確認虛擬機密碼。',
  resourceBounds: '{resource} 須為 {min} 到 {max} 之間的整數。',
  checkingOwner: '正在檢查所屬主閘道…',
  ownerUnavailable: '無法驗證所屬主閘道。請關閉建立視窗，選擇主閘道後重新開啟。',
  lookupFailed: '無法查詢已儲存的請求。再次提交前請重試查詢。',
  submitting: '正在提交請求…',
  reservedUsername: '此 Linux 使用者名稱已保留。請選擇其他機器人名稱。',
  resumePassword: '找不到要求。請重新輸入相同的虛擬機密碼後重試此要求。',
  loginUnavailable: '虛擬機登入設定無法使用。請先更新主閘道，再建立機器人。',
  loginRules:
    '名稱須以小寫英文字母開頭，包含 1–32 個小寫英文字母、數字、底線或連字號。密碼須為 8–256 位元組且不含換行。',
  username: 'Linux 使用者名稱',
  password: '虛擬機密碼',
  confirmPassword: '確認虛擬機密碼',
  passwordMismatch: '兩次輸入的密碼不一致。',
  loginDescription: 'Linux 使用者名稱與機器人名稱相同。此密碼用於登入虛擬機，與控制器登入不同。',
  createProfile: '在現有閘道上建立設定檔',
  storageFailed: '無法儲存操作以安全重試。未傳送命令。',
  recover: '檢查虛擬機狀態',
  recoverConfirm: '重新整理狀態並確認命令結果未知。之後的電源操作將是新命令，可能中斷工作。',
  remoteTitle: '遠端虛擬機',
  controlUnavailable: '此閘道不支援虛擬機控制。',
  connecting: '連線中…',
  start: '啟動',
  stop: '停止',
  restart: '重新啟動',
  refresh: '重新整理',
  resources: '資源',
  running: '執行中',
  starting: '啟動中',
  stopping: '停止中',
  stopped: '已停止',
  unknown: '未知',
  screen: '畫面',
  terminal: '終端機',
  connected: '已連線',
  disconnected: '連線已中斷。重新連線可恢復工作階段。',
  superseded: '另一用戶端已接管終端機。重新連線可接管控制。',
  exited: 'Shell 已結束。重新連線將開啟新 Shell。',
  terminalUnavailable: '訪客終端機無法使用。請更新執行環境並檢查 tmux。',
  reconnect: '重新連線',
  persistent: '關閉此面板後，虛擬機、桌面和 Shell 會繼續執行。',
  powerUnknown: '命令結果未知。重試使用相同操作 ID，不會重複重新啟動。',
  retryPower: '重試同一操作',
  connectionFailed: '無法連線至所選虛擬機或主閘道，請重新整理。',
  powerConfirm: '此操作會中斷該虛擬機中的工作。磁碟和檔案會保留。',
  operation: '電源命令',
  operation_queued: '排隊中',
  operation_dispatching: '傳送中',
  operation_accepted: '已接受，等待虛擬機狀態',
  operation_unknown: '結果未知。執行下一操作前請重新整理虛擬機狀態。',
  operation_failed: '失敗',
  title: '建立 Linux 虛擬機',
  description: '在主閘道上建立持久且隔離的 Linux 安裝。關閉視窗後仍會繼續。就緒後請設定模型。',
  name: '機器人名稱',
  cpu: 'CPU 核心',
  memory_mib: '記憶體 (MiB)',
  disk_gib: '磁碟 (GiB)',
  copy: '複製主閘道的供應商 API 金鑰',
  exclusions:
    '僅複製列出的供應商 API 金鑰。模型設定獨立。每個機器人都需要單獨登入 Codex。不包含 OAuth 登入、訊息身分和叢集憑證。',
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
