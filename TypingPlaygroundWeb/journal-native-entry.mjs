import { toHiragana } from 'wanakana';
import { JournalNativeSession } from './journal-native-session.mjs';
globalThis.makeJournalSession = () => new JournalNativeSession(toHiragana);
