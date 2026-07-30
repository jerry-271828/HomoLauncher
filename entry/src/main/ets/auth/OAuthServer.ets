import { EventHub, Xb_Copy, Xb_FileUtils, Xb_GetResourceString, Xb_GoToWeb, Xb_ToastUtil } from 'xb_components';
import { EventKey } from '../common/EventKey';
import { Callback, Session,} from './OAuth';

// 保证编译进 resources.index 的值非空；小白调试助手 3.1 无法解析零长度资源。
const UNCONFIGURED_MICROSOFT_CLIENT_ID = "__UNCONFIGURED_MICROSOFT_CLIENT_ID__"

export function getMicrosoftClientId(): string {
  const clientId = Xb_GetResourceString($r("app.string.MicrosortAuthClientId"))
  return clientId === UNCONFIGURED_MICROSOFT_CLIENT_ID ? "" : clientId
}

export interface GrantDeviceCodeEvent{
  userCode: string
  verificationUri: string
}

export class OAuthServer implements Callback{

  startServer(): Promise<Session> {
    throw new Error('Method not implemented.');
  }

  grantDeviceCode(userCode: string, verificationUri: string): void {
    EventHub.sendEvent<GrantDeviceCodeEvent>(EventKey.GrantDeviceCodeEvent, {userCode, verificationUri})
    Xb_Copy(userCode)
    Xb_ToastUtil.showToast({message:"设备码已复制"})
  }

  async openBrowser(url: string): Promise<void> {
    Xb_GoToWeb(url)
  }

  getClientId(): string {
    return getMicrosoftClientId()
  }

  getClientSecret(): string | null {
    return null
  }

  isPublicClient(): boolean {
   return true
  }

}
