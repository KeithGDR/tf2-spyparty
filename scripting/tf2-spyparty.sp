/*****************************/
//Pragma
#pragma semicolon 1
#pragma newdecls required

/*****************************/
//Defines
#define PLUGIN_NAME "[TF2] Spy Party"
#define PLUGIN_DESCRIPTION "An experimental gamemode where you have to assassinate spies attempting to complete objectives."
#define PLUGIN_VERSION "1.0.0"

#define STATE_HIBERNATION 0
#define STATE_LOBBY 1
#define STATE_PLAYING 2

#define ACTION_GIVE 0

/*****************************/
//Includes

#include <sourcemod>
#include <sdkhooks>
#include <dhooks>
#include <tf2_stocks>
#include <tf2items>
#include <tf2attributes>
#include <misc-colors>
#include <customkeyvalues>
#include <cbasenpc>
#include <cbasenpc/util>

/*****************************/
//ConVars

ConVar convar_TeamBalance;
ConVar convar_GivenTasks;
ConVar convar_Glows;

ConVar convar_AllTalk;
ConVar convar_RespawnWaveTime;
ConVar convar_AutoTeamBalance;
ConVar convar_TeamBalanceLimit;
ConVar convar_AutoScramble;

/*****************************/
//Globals

Database g_Database;
bool g_Late;

char sModels[10][PLATFORM_MAX_PATH] =
{
	"",
	"models/player/scout.mdl",
	"models/player/sniper.mdl",
	"models/player/soldier.mdl",
	"models/player/demo.mdl",
	"models/player/medic.mdl",
	"models/player/heavy.mdl",
	"models/player/pyro.mdl",
	"models/player/spy.mdl",
	"models/player/engineer.mdl"
};

enum TF2Quality {
	TF2Quality_Normal = 0, // 0
	TF2Quality_Rarity1,
	TF2Quality_Genuine = 1,
	TF2Quality_Rarity2,
	TF2Quality_Vintage,
	TF2Quality_Rarity3,
	TF2Quality_Rarity4,
	TF2Quality_Unusual = 5,
	TF2Quality_Unique,
	TF2Quality_Community,
	TF2Quality_Developer,
	TF2Quality_Selfmade,
	TF2Quality_Customized, // 10
	TF2Quality_Strange,
	TF2Quality_Completed,
	TF2Quality_Haunted,
	TF2Quality_ToborA
};

int g_GlowSprite;
int g_LaserSprite;
int g_HaloSprite;

enum struct Match
{
	Handle hud;
	int matchstate;

	int lobbytime;
	Handle lobbytimer;

	int lockdowntime;

	int totaltasks;
	int totalshots;

	int givetasks;
	Handle givetaskstimer;

	int spytask;

	bool spyhasdonetask;
	Handle unlocksnipers;

	bool ispaused;

	float spawnertimer;
	Handle spawner;
}

Match g_Match;

enum struct Player
{
	int index;

	bool changeclass;
	int lastchangedclass;

	bool isspy;
	bool isbenefactor;

	int benefactornoises;
	int lastrefilled;

	ArrayList requiredtasks;

	int neartask;
	int glowent;

	int queuepoints;

	float tasktimer;
	Handle doingtask;

	bool ismarked;

	void Init(int client)
	{
		this.index = client;
	}

	int GetQueuePosition(int& total)
	{
		int position;

		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && GetClientTeam(i) > 1)
			{
				total++;
				if (GetPoints(i) > this.queuepoints)
					position++;
			}
		}

		return position;
	}
}

Player g_Player[MAXPLAYERS + 1];

int GetPoints(int client)
{
	return g_Player[client].queuepoints;
}

enum struct Tasks
{
	char name[128];
	char trigger[128];

	void Add(const char[] name, const char[] trigger)
	{
		strcopy(this.name, 128, name);
		strcopy(this.trigger, 128, trigger);
	}
}

Tasks g_Tasks[32];
int g_TotalTasks;

Handle g_OnWeaponFire;

PathFollower pPath[MAX_NPCS];
int g_NPCTask[MAX_NPCS];

/*****************************/
//Plugin Info
public Plugin myinfo = 
{
	name = PLUGIN_NAME, 
	author = "Drixevel", 
	description = PLUGIN_DESCRIPTION, 
	version = PLUGIN_VERSION, 
	url = "https://drixevel.dev/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_Late = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	if (TheNavMesh) { }
	CSetPrefix("{darkblue}[{azure}SpyParty{darkblue}]{honeydew}");

	LoadTranslations("common.phrases");

	convar_TeamBalance = CreateConVar("sm_spyparty_teambalance", "0.35", "How many more reds should there be for blues?", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	convar_GivenTasks = CreateConVar("sm_spyparty_giventasks", "2", "How many tasks do players get per tick?", FCVAR_NOTIFY, true, 1.0);
	convar_Glows = CreateConVar("sm_spyparty_glows", "0", "Enable glows for players?", FCVAR_NOTIFY, true, 1.0);

	convar_AllTalk = FindConVar("sv_alltalk");
	convar_RespawnWaveTime = FindConVar("mp_respawnwavetime");
	convar_AutoTeamBalance = FindConVar("mp_autoteambalance");
	convar_TeamBalanceLimit = FindConVar("mp_teams_unbalance_limit");
	convar_AutoScramble = FindConVar("mp_scrambleteams_auto");

	RegAdminCmd("sm_tasks", Command_Tasks, ADMFLAG_ROOT, "Show what tasks you have.");

	RegAdminCmd("sm_start", Command_Start, ADMFLAG_ROOT, "Start the match.");
	RegAdminCmd("sm_startmatch", Command_Start, ADMFLAG_ROOT, "Start the match.");
	RegAdminCmd("sm_givetask", Command_GiveTask, ADMFLAG_ROOT, "Give yourself or others a task.");
	RegAdminCmd("sm_spy", Command_Spy, ADMFLAG_ROOT, "Prints out who the spy is in chat.");

	RegConsoleCmd("sm_queuepoints", Command_QueuePoints, "Shows you how many queue points you have.");
	RegAdminCmd("sm_setqueuepoints", Command_SetQueuePoints, ADMFLAG_ROOT, "Set your own or somebody else's queue points.");

	RegAdminCmd("sm_pause", Command_Pause, ADMFLAG_ROOT, "Pause the timer.");
	RegAdminCmd("sm_pausetimer", Command_Pause, ADMFLAG_ROOT, "Pause the timer.");
	RegAdminCmd("sm_unpause", Command_Unpause, ADMFLAG_ROOT, "Unpause the timer.");
	RegAdminCmd("sm_unpausetimer", Command_Unpause, ADMFLAG_ROOT, "Unpause the timer.");

	HookEvent("player_spawn", Event_OnPlayerSpawn);
	HookEvent("player_changeclass", Event_OnPlayerChangeClass);
	HookEvent("player_death", Event_OnPlayerDeath);
	HookEvent("teamplay_round_start", Event_OnRoundStart);
	HookEvent("teamplay_round_win", Event_OnRoundEnd);

	AddCommandListener(Listener_VoiceMenu, "voicemenu");

	g_Match.hud = CreateHudSynchronizer();

	GameData config;
	if ((config = new GameData("tf2.spyparty")) != null)
	{
		int offset = config.GetOffset("CBasePlayer::OnMyWeaponFired");
		
		if (offset != -1)
		{
			g_OnWeaponFire = DHookCreate(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, OnMyWeaponFired);
			DHookAddParam(g_OnWeaponFire, HookParamType_Int);
			LogError("Gamedata Hooked: CBasePlayer::OnMyWeaponFired");
		}
		else
			LogError("Error while parsing Gamedata: CBasePlayer::OnMyWeaponFired");

		delete config;
	}
	else
		LogError("Error while parsing Gamedata File: tf2.spyparty.txt");
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
			OnClientConnected(i);
		
		if (!IsClientInGame(i))
			continue;
		
		OnClientPutInServer(i);
		
		if (IsPlayerAlive(i))
			OnSpawn(i);
	}

	int entity = -1; char classname[64];
	while ((entity = FindEntityByClassname(entity, "*")) != -1)
		if (GetEntityClassname(entity, classname, sizeof(classname)))
			OnEntityCreated(entity, classname);
	
	ParseTasks();

	convar_RespawnWaveTime.IntValue = 10;
	convar_AutoTeamBalance.IntValue = 0;
	convar_TeamBalanceLimit.IntValue = 0;
	convar_AutoScramble.IntValue = 0;

	for (int i = 0; i < MAX_NPCS; i++)
		pPath[i] = PathFollower(_, Path_FilterIgnoreActors, Path_FilterOnlyActors);
	
	RegAdminCmd("sm_spawnnpc", Command_SpawnNPC, ADMFLAG_ROOT, "Manually spawn an NPC.");

	Database.Connect(OnSQLConnect, "default");
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		
		if (!IsFakeClient(i))
			ClearSyncHud(i, g_Match.hud);

		if (IsPlayerAlive(i) && g_Player[i].glowent > 0 && IsValidEntity(g_Player[i].glowent))
			RemoveEntity(g_Player[i].glowent);
	}

	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "base_boss")) != -1)
		RemoveEntity(entity);

	PauseTF2Timer();

	convar_RespawnWaveTime.IntValue = 10;
	convar_AutoTeamBalance.IntValue = 0;
	convar_TeamBalanceLimit.IntValue = 0;
	convar_AutoScramble.IntValue = 0;
}

public void OnConfigsExecuted()
{
	FindConVar("sv_alltalk").Flags = FindConVar("sv_alltalk").Flags &= ~FCVAR_NOTIFY;
	FindConVar("mp_respawnwavetime").Flags = FindConVar("mp_respawnwavetime").Flags &= ~FCVAR_NOTIFY;
	FindConVar("sv_tags").Flags = FindConVar("sv_tags").Flags &= ~FCVAR_NOTIFY;

	convar_RespawnWaveTime.IntValue = 10;
	convar_AutoTeamBalance.IntValue = 0;
	convar_TeamBalanceLimit.IntValue = 0;
	convar_AutoScramble.IntValue = 0;

	convar_AllTalk.BoolValue = true;
}

public void OnMapStart()
{
	g_GlowSprite = PrecacheModel("materials/sprites/blueglow2.vmt");
	g_LaserSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
	g_HaloSprite = PrecacheModel("materials/sprites/halo01.vmt");

	PrecacheSound("coach/coach_go_here.wav");
	PrecacheSound("coach/coach_defend_here.wav");
	PrecacheSound("coach/coach_look_here.wav");
	PrecacheSound("ambient/alarms/doomsday_lift_alarm.wav");
	PrecacheSound("ambient/chamber_open.wav");
	PrecacheSound("misc/freeze_cam_snapshot.wav");
	PrecacheSound("weapons/jar_single.wav");
	PrecacheSound("ui/duel_score_behind.wav");
	PrecacheSound("passtime/ball_catch.wav");
	PrecacheSound("player/pl_scout_dodge_can_drink.wav");
	PrecacheSound("npc/headcrab/headcrab_burning_loop2.wav");
	PrecacheSound("doors/default_locked.wav");

	convar_RespawnWaveTime.IntValue = 10;
}

public void OnMapEnd()
{
	g_Match.matchstate = STATE_HIBERNATION;

	g_Match.lobbytimer = null;
	g_Match.givetaskstimer = null;
	g_Match.unlocksnipers = null;

	convar_RespawnWaveTime.IntValue = 10;
}

public void OnClientConnected(int client)
{
	g_Player[client].Init(client);
}

public void OnClientAuthorized(int client, const char[] auth)
{
	g_Player[client].queuepoints = 0;

	if (IsFakeClient(client) || g_Database == null)
		return;
	
	char sQuery[256];
	g_Database.Format(sQuery, sizeof(sQuery), "SELECT points FROM `spyparty_points` WHERE auth = '%s';", auth);
	g_Database.Query(OnParsePoints, sQuery, GetClientUserId(client));
}

public void OnParsePoints(Database db, DBResultSet results, const char[] error, any data)
{
	int client;
	if ((client = GetClientOfUserId(data)) == 0)
		return;
	
	if (results == null)
		ThrowError("Error while parsing points: %s", error);
	
	if (results.FetchRow())
		g_Player[client].queuepoints = results.FetchInt(0);
	else
	{
		char auth[64];
		GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));

		char sQuery[256];
		g_Database.Format(sQuery, sizeof(sQuery), "INSERT INTO `spyparty_points` (auth) VALUES ('%s');", auth);
		g_Database.Query(OnInsertPoints, sQuery);
	}
}

public void OnInsertPoints(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
		ThrowError("Error while inserting points: %s", error);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);

	delete g_Player[client].requiredtasks;
	g_Player[client].requiredtasks = new ArrayList();

	if (g_OnWeaponFire != null)
		DHookEntity(g_OnWeaponFire, true, client);
}

public void OnClientDisconnect(int client)
{
	if (g_Player[client].glowent > 0 && IsValidEntity(g_Player[client].glowent))
		RemoveEntity(g_Player[client].glowent);
	
	SaveQueuePoints(client);
}

void SaveQueuePoints(int client)
{
	char auth[64];
	if (g_Database != null && GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
	{
		char sQuery[256];
		g_Database.Format(sQuery, sizeof(sQuery), "UPDATE `spyparty_points` SET points = '%i' WHERE auth = '%s';", g_Player[client].queuepoints, auth);
		g_Database.Query(OnSavePoints, sQuery);
	}
}

public void OnSavePoints(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
		ThrowError("Error while saving points: %s", error);
}

public void OnClientDisconnect_Post(int client)
{
	g_Player[client].isspy = false;
	g_Player[client].isbenefactor = false;
	g_Player[client].ismarked = false;

	g_Player[client].benefactornoises = 0;

	g_Player[client].lastrefilled = -1;

	delete g_Player[client].requiredtasks;
	g_Player[client].neartask = -1;

	g_Player[client].glowent = -1;

	g_Player[client].queuepoints = 0;

	g_Player[client].changeclass = false;
	g_Player[client].lastchangedclass = -1;
}

public Action OnTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype)
{
	if ((damagetype & DMG_BURN) == DMG_BURN)
		return Plugin_Continue;
	
	if ((damagetype & DMG_FALL) == DMG_FALL)
	{
		damage = 0.0;
		return Plugin_Changed;
	}

	if (attacker > 0 && attacker <= MaxClients && GetClientTeam(attacker) == 3 && GetClientTeam(victim) != GetClientTeam(attacker))
	{
		damage = 0.0;
		return Plugin_Changed;
	}

	damage = 500.0;
	return Plugin_Changed;
}

void ParseTasks()
{
	g_TotalTasks = 0;

	int entity = -1; char sClassname[64]; char sName[64];
	while ((entity = FindEntityByClassname(entity, "trigger_multiple")) != -1)
	{
		GetEntPropString(entity, Prop_Data, "m_iName", sClassname, sizeof(sClassname));

		if (StrContains(sClassname, "task_", false) != 0)
				continue;
		
		GetCustomKeyValue(entity, "task", sName,  sizeof(sName));
		
		g_Tasks[g_TotalTasks++].Add(sName, sClassname);
	}
}

void AddTask(int client, int task)
{
	if (g_Player[client].isspy && GetRandomInt(0, 10) > 2)
		task = g_Match.spytask;
	
	if (g_Player[client].requiredtasks.FindValue(task) != -1)
		task = GetRandomInt(0, g_TotalTasks - 1);
	
	g_Player[client].requiredtasks.Push(task);
	CPrintToChat(client, "You have been given the task: {azure}%s", g_Tasks[task].name);
	UpdateHud(client);

	EmitSoundToClient(client, "coach/coach_go_here.wav");
}

bool CompleteTask(int client, int task)
{
	if (!HasTask(client, task))
		return false;
	
	int index = g_Player[client].requiredtasks.FindValue(task);
	g_Player[client].requiredtasks.Erase(index);

	CPrintToChat(client, "You have completed the task: {azure}%s", g_Tasks[task].name);

	if (StrEqual(g_Tasks[task].name, "Execute a Command", false))
	{
		EmitSoundToClient(client, "ambient/chamber_open.wav");
	}
	else if (StrEqual(g_Tasks[task].name, "Replace the Film", false))
	{
		EmitSoundToClient(client, "misc/freeze_cam_snapshot.wav");
	}
	else if (StrEqual(g_Tasks[task].name, "Water the Plants", false))
	{
		EmitSoundToClient(client, "weapons/jar_single.wav");
	}
	else if (StrEqual(g_Tasks[task].name, "Replace Hard Disk", false))
	{
		EmitSoundToClient(client, "ambient/chamber_open.wav");
	}
	else if (StrEqual(g_Tasks[task].name, "Plot World Domination", false))
	{
		EmitSoundToClient(client, "ui/duel_score_behind.wav");
	}
	else if (StrEqual(g_Tasks[task].name, "Play Pool", false))
	{
		EmitSoundToClient(client, "passtime/ball_catch.wav");
	}
	else if (StrEqual(g_Tasks[task].name, "Get Drunk", false))
	{
		EmitSoundToClient(client, "player/pl_scout_dodge_can_drink.wav");
	}
	else if (StrEqual(g_Tasks[task].name, "Make Coffee", false))
	{
		EmitSoundToClient(client, "player/pl_scout_dodge_can_drink.wav");
	}
	else if (StrEqual(g_Tasks[task].name, "Cook Food", false))
	{
		EmitSoundToClient(client, "npc/headcrab/headcrab_burning_loop2.wav");
	}

	EmitSoundToClient(client, "coach/coach_defend_here.wav");

	if (g_Player[client].isspy && task == g_Match.spytask)
	{
		EmitSoundToAll("coach/coach_look_here.wav");

		g_Match.spyhasdonetask = true;
		StopTimer(g_Match.unlocksnipers);
	}
	
	AddTime();
	g_Match.totaltasks++;

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			UpdateHud(i);

	if (g_Match.totaltasks >= GetMaxTasks())
	{
		CPrintToChatAll("Blue team has completed all available tasks, Blue wins the round.");
		TF2_ForceWin(TFTeam_Blue);
		return true;
	}

	ShowTasksPanel(client);
	return true;
}

int GetTasksCount(int client)
{
	return g_Player[client].requiredtasks.Length;
}

bool HasTask(int client, int task)
{
	if (g_Player[client].requiredtasks.FindValue(task) != -1)
		return true;
	
	return false;
}

public Action Command_GiveTask(int client, int args)
{
	OpenTasksMenu(client, ACTION_GIVE);
	return Plugin_Handled;
}

void OpenTasksMenu(int client, int action)
{
	Menu menu = new Menu(MenuHandler_Tasks);
	menu.SetTitle("Pick a task:");

	char sID[16];
	for (int i = 0; i < g_TotalTasks; i++)
	{
		IntToString(i, sID, sizeof(sID));
		menu.AddItem(sID, g_Tasks[i].name);
	}
	
	PushMenuInt(menu, "action", action);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Tasks(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[16];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			int task = StringToInt(sInfo);
			int chosen_action = GetMenuInt(menu, "action");

			switch (chosen_action)
			{
				case ACTION_GIVE:
				{
					AddTask(param1, task);
				}
			}

			OpenTasksMenu(param1, chosen_action);
		}

		case MenuAction_End:
			delete menu;
	}
}

public void Event_OnPlayerChangeClass(Event event, const char[] name, bool dontBroadcast)
{
	int client;
	if ((client = GetClientOfUserId(event.GetInt("userid"))) == 0)
		return;
	
	OnSpawn(client);
}

public void Event_OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	CreateTimer(0.2, Timer_DelaySpawn, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE);

	if (g_Match.matchstate == STATE_HIBERNATION)
		InitLobby();
}

public Action Timer_DelaySpawn(Handle timer, any data)
{
	int client;
	if ((client = GetClientOfUserId(data)) == 0)
		return Plugin_Stop;
	
	if (g_Player[client].glowent > 0 && IsValidEntity(g_Player[client].glowent))
	{
		RemoveEntity(g_Player[client].glowent);
		g_Player[client].glowent = -1;
	}
	
	OnSpawn(client);

	return Plugin_Stop;
}

void OnSpawn(int client)
{
	if (IsPlayerAlive(client))
	{
		switch (TF2_GetClientTeam(client))
		{
			case TFTeam_Red:
			{
				TF2_SetPlayerClass(client, TFClass_Sniper);
				TF2_RegeneratePlayer(client);

				int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");

				if (!IsValidEntity(weapon) || IsValidEntity(weapon) && GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") != 526)
				{
					TF2_RemoveWeaponSlot(client, TFWeaponSlot_Primary);
					TF2_GiveItem(client, "tf_weapon_sniperrifle", 526, TF2Quality_Normal, 0, "");
				}

				EquipWeaponSlot(client, TFWeaponSlot_Primary);

				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Secondary);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Melee);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Grenade);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Building);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_PDA);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Item1);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Item2);

				int entity;
				while ((entity = FindEntityByClassname(entity, "tf_wearable_")) != -1)
					if (GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity") == client)
						TF2_RemoveWearable(client, entity);

				weapon = -1;
				for (int slot = 0; slot < 3; slot++)
					if ((weapon = GetPlayerWeaponSlot(client, slot)) != -1)
						SetWeaponAmmo(client, weapon, 1);
				
				TF2Attrib_ApplyMoveSpeedBonus(client, 0.8);
			}

			case TFTeam_Blue:
			{
				if (TF2_GetPlayerClass(client) == TFClass_Spy || TF2_GetPlayerClass(client) == TFClass_Sniper)
					TF2_SetPlayerClass(client, GetRandomClass());
				
				TF2_RegeneratePlayer(client);

				EquipWeaponSlot(client, TFWeaponSlot_Melee);

				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Primary);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Secondary);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Grenade);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Building);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_PDA);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Item1);
				TF2_RemoveWeaponSlot(client, TFWeaponSlot_Item2);

				int entity;
				while ((entity = FindEntityByClassname(entity, "tf_wearable_")) != -1)
					if (GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity") == client)
						TF2_RemoveWearable(client, entity);

				if (convar_Glows.BoolValue)
					g_Player[client].glowent = TF2_CreateGlow("blue_glow", client);
				
				if (IsValidEntity(g_Player[client].glowent))
					SDKHook(g_Player[client].glowent, SDKHook_SetTransmit, OnTransmitGlow);
				
				TF2Attrib_RemoveMoveSpeedBonus(client);
			}
		}
	}
	else 
		TF2_RespawnPlayer(client);

	if (g_Match.matchstate == STATE_HIBERNATION)
		InitLobby();

	CreateTimer(0.2, Timer_Hud, GetClientUserId(client));
	CreateTimer(0.2, Timer_SetHealth, GetClientUserId(client));
}

public Action Timer_SetHealth(Handle timer, any data)
{
	int client;
	if ((client = GetClientOfUserId(data)) > 0 && IsClientInGame(client) && IsPlayerAlive(client))
		SetEntityHealth(client, GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iMaxHealth", _, client));
}

TFClassType GetRandomClass()
{
	TFClassType class[7];

	class[0] = TFClass_Scout;
	class[1] = TFClass_Soldier;
	class[2] = TFClass_DemoMan;
	class[3] = TFClass_Medic;
	class[4] = TFClass_Heavy;
	class[5] = TFClass_Pyro;
	class[6] = TFClass_Engineer;

	return class[GetRandomInt(0, 6)];
}

public Action OnTransmitGlow(int entity, int client)
{
	SetEdictFlags(entity, GetEdictFlags(entity) & ~FL_EDICT_ALWAYS);
	
	int owner = GetEntPropEnt(entity, Prop_Send, "m_hTarget");

	if (owner < 1 || owner > MaxClients || client < 1 || client > MaxClients)
		return Plugin_Continue;
	
	if (owner == client || TF2_GetClientTeam(owner) == TF2_GetClientTeam(client))
		return Plugin_Handled;
	
	return Plugin_Continue;
}

public Action Timer_Hud(Handle timer, any data)
{
	int client;
	if ((client = GetClientOfUserId(data)) > 0)
		UpdateHud(client);
}

int TF2_GiveItem(int client, char[] classname, int index, TF2Quality quality = TF2Quality_Normal, int level = 0, const char[] attributes = "")
{
	char sClass[64];
	strcopy(sClass, sizeof(sClass), classname);
	
	if (StrContains(sClass, "saxxy", false) != -1)
	{
		switch (TF2_GetPlayerClass(client))
		{
			case TFClass_Scout: strcopy(sClass, sizeof(sClass), "tf_weapon_bat");
			case TFClass_Sniper: strcopy(sClass, sizeof(sClass), "tf_weapon_club");
			case TFClass_Soldier: strcopy(sClass, sizeof(sClass), "tf_weapon_shovel");
			case TFClass_DemoMan: strcopy(sClass, sizeof(sClass), "tf_weapon_bottle");
			case TFClass_Engineer: strcopy(sClass, sizeof(sClass), "tf_weapon_wrench");
			case TFClass_Pyro: strcopy(sClass, sizeof(sClass), "tf_weapon_fireaxe");
			case TFClass_Heavy: strcopy(sClass, sizeof(sClass), "tf_weapon_fists");
			case TFClass_Spy: strcopy(sClass, sizeof(sClass), "tf_weapon_knife");
			case TFClass_Medic: strcopy(sClass, sizeof(sClass), "tf_weapon_bonesaw");
		}
	}
	else if (StrContains(sClass, "shotgun", false) != -1)
	{
		switch (TF2_GetPlayerClass(client))
		{
			case TFClass_Soldier: strcopy(sClass, sizeof(sClass), "tf_weapon_shotgun_soldier");
			case TFClass_Pyro: strcopy(sClass, sizeof(sClass), "tf_weapon_shotgun_pyro");
			case TFClass_Heavy: strcopy(sClass, sizeof(sClass), "tf_weapon_shotgun_hwg");
			case TFClass_Engineer: strcopy(sClass, sizeof(sClass), "tf_weapon_shotgun_primary");
		}
	}
	
	Handle item = TF2Items_CreateItem(PRESERVE_ATTRIBUTES | FORCE_GENERATION);	//Keep reserve attributes otherwise random issues will occur... including crashes.
	TF2Items_SetClassname(item, sClass);
	TF2Items_SetItemIndex(item, index);
	TF2Items_SetQuality(item, view_as<int>(quality));
	TF2Items_SetLevel(item, level);
	
	char sAttrs[32][32];
	int count = ExplodeString(attributes, " ; ", sAttrs, 32, 32);
	
	if (count > 1)
	{
		TF2Items_SetNumAttributes(item, count / 2);
		
		int i2;
		for (int i = 0; i < count; i += 2)
		{
			TF2Items_SetAttribute(item, i2, StringToInt(sAttrs[i]), StringToFloat(sAttrs[i + 1]));
			i2++;
		}
	}
	else
		TF2Items_SetNumAttributes(item, 0);

	int weapon = TF2Items_GiveNamedItem(client, item);
	delete item;
	
	if (StrEqual(sClass, "tf_weapon_builder", false) || StrEqual(sClass, "tf_weapon_sapper", false))
	{
		SetEntProp(weapon, Prop_Send, "m_iObjectType", 3);
		SetEntProp(weapon, Prop_Data, "m_iSubType", 3);
		SetEntProp(weapon, Prop_Send, "m_aBuildableObjectTypes", 0, _, 0);
		SetEntProp(weapon, Prop_Send, "m_aBuildableObjectTypes", 0, _, 1);
		SetEntProp(weapon, Prop_Send, "m_aBuildableObjectTypes", 0, _, 2);
		SetEntProp(weapon, Prop_Send, "m_aBuildableObjectTypes", 1, _, 3);
	}
	
	if (StrContains(sClass, "tf_weapon_", false) == 0)
		EquipPlayerWeapon(client, weapon);
	
	SetEntProp(weapon, Prop_Send, "m_bValidatedAttachedEntity", 1);
	
	return weapon;
}

public void Event_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	CreateTimer(0.5, Timer_CheckDeath, _, TIMER_FLAG_NO_MAPCHANGE);

	int client;
	if ((client = GetClientOfUserId(event.GetInt("userid"))) == 0)
		return;
	
	if (g_Player[client].glowent > 0 && IsValidEntity(g_Player[client].glowent))
	{
		RemoveEntity(g_Player[client].glowent);
		g_Player[client].glowent = -1;
	}
	
	if (TF2_GetClientTeam(client) != TFTeam_Blue || g_Match.matchstate != STATE_PLAYING)
		return;
	
	if (g_Player[client].isspy)
	{
		CPrintToChatAll("{azure}%N {honeydew}was a spy and has died!", client);
		TF2_SetPlayerClass(client, TFClass_Spy);
		g_Player[client].isspy = false;
	}
	else if (g_Player[client].isbenefactor)
	{
		CPrintToChatAll("{ancient}%N {honeydew}was a benefactor and has died!", client);
		g_Player[client].isbenefactor = false;
	}
	else
	{
		CPrintToChatAll("{aliceblue}%N {honeydew}was NOT a spy and has died!", client);

		int attacker;
		if ((attacker = GetClientOfUserId(event.GetInt("attacker"))) != -1)
		{
			CPrintToChat(attacker, "You have shot the wrong target!");
			TF2_IgnitePlayer(attacker, attacker, 10.0);
		}
	}
}

public Action Timer_CheckDeath(Handle timer)
{
	if (g_Match.matchstate == STATE_PLAYING)
	{
		int count;

		count = 0;
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == 2)
				count++;
		
		if (count < 1)
			TF2_ForceWin(TFTeam_Blue);
		
		count = 0;
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == 3)
				count++;
		
		if (count < 1)
			TF2_ForceWin(TFTeam_Red);
		
		count = 0;
		for (int i = 1; i <= MaxClients; i++)
			if (g_Player[i].isspy)
				count++;
		
		if (count < 1)
		{
			CPrintToChatAll("Red has eliminated all spies on the Blue team, Red wins the round.");
			TF2_ForceWin(TFTeam_Red);
		}
	}
}

void TF2_ForceWin(TFTeam team = TFTeam_Unassigned)
{
	int iFlags = GetCommandFlags("mp_forcewin");
	SetCommandFlags("mp_forcewin", iFlags &= ~FCVAR_CHEAT);
	ServerCommand("mp_forcewin %i", view_as<int>(team));
	SetCommandFlags("mp_forcewin", iFlags);
}

void EquipWeaponSlot(int client, int slot)
{
	int iWeapon = GetPlayerWeaponSlot(client, slot);
	
	if (IsValidEntity(iWeapon))
	{
		char class[64];
		GetEntityClassname(iWeapon, class, sizeof(class));
		FakeClientCommand(client, "use %s", class);
	}
}

void UpdateHudAll()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i))
			UpdateHud(i);
}

void UpdateHud(int client)
{
	char sMatchState[32];
	GetMatchStateName(sMatchState, sizeof(sMatchState));

	char sTeamHud[64];
	if (g_Match.matchstate == STATE_PLAYING)
	{
		switch (TF2_GetClientTeam(client))
		{
			case TFTeam_Red, TFTeam_Spectator:
			{
				FormatEx(sTeamHud, sizeof(sTeamHud), "Total Shots: %i/%i", g_Match.totalshots, GetMaxShots());
			}

			case TFTeam_Blue:
			{
				int tasks = GetTasksCount(client);
				FormatEx(sTeamHud, sizeof(sTeamHud), "Available Tasks: %i", tasks);
			}
		}
	}

	char sTotalTasks[64];
	if (g_Match.matchstate == STATE_PLAYING)
		FormatEx(sTotalTasks, sizeof(sTotalTasks), "\nTotal Tasks: %i/%i", g_Match.totaltasks, GetMaxTasks());
	
	int count;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayerAlive(i))
			count++;

	char sWarning[32];
	if (count < 3 && g_Match.matchstate == STATE_LOBBY)
		FormatEx(sWarning, sizeof(sWarning), "(Requires 3 players to start)");

	SetHudTextParams(0.0, 0.0, 99999.0, 255, 255, 255, 255);
	ShowSyncHudText(client, g_Match.hud, "Match State: %s (Queue Points: %i)\n%s%s%s", sMatchState, g_Player[client].queuepoints, sTeamHud, sTotalTasks, sWarning);
}

int GetMaxTasks()
{
	int tasks;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayerAlive(i) && TF2_GetClientTeam(i) == TFTeam_Blue)
			tasks += 5;
	
	return tasks;
}

void GetMatchStateName(char[] buffer, int size)
{
	switch (g_Match.matchstate)
	{
		case STATE_HIBERNATION:
			strcopy(buffer, size, "Hibernation");
		case STATE_LOBBY:
			strcopy(buffer, size, "Starting");
		case STATE_PLAYING:
			strcopy(buffer, size, "Live");
	}
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (g_Match.matchstate == STATE_PLAYING)
	{
		if (TF2_GetClientTeam(client) == TFTeam_Blue)
		{
			for (int i = 0; i < g_Player[client].requiredtasks.Length; i++)
			{
				int task = g_Player[client].requiredtasks.Get(i);

				if (task == -1)
					continue;
				
				int entity = FindEntityByName(g_Tasks[task].trigger, "trigger_multiple");

				if (!IsValidEntity(entity))
					continue;
				
				float vecDestStart[3]; float vecDestEnd[3];
				GetAbsBoundingBox(entity, vecDestStart, vecDestEnd);
				Effect_DrawBeamBoxToClient(client, vecDestStart, vecDestEnd, g_LaserSprite, g_HaloSprite, 30, 30, 0.5, 2.0, 2.0, 1, 5.0, {0, 191, 255, 120}, 0);
			}
		}
		else if (TF2_GetClientTeam(client) == TFTeam_Red)
		{
			if (!g_Match.spyhasdonetask)
				SetEntPropFloat(client, Prop_Send, "m_flNextAttack", GetGameTime() + 2.0);
		}
	}
	else
	{
		if (TF2_GetClientTeam(client) == TFTeam_Red)
			SetEntPropFloat(client, Prop_Send, "m_flNextAttack", GetGameTime() + 999.0);
	}
}

stock bool GetClientLookOrigin(int client, float pOrigin[3], bool filter_players = true, float distance = 35.0)
{
	if (client == 0 || client > MaxClients || !IsClientInGame(client))
		return false;

	float vOrigin[3];
	GetClientEyePosition(client,vOrigin);

	float vAngles[3];
	GetClientEyeAngles(client, vAngles);

	Handle trace = TR_TraceRayFilterEx(vOrigin, vAngles, MASK_SHOT, RayType_Infinite, filter_players ? TraceEntityFilterPlayer : TraceEntityFilterNone, client);
	bool bReturn = TR_DidHit(trace);

	if (bReturn)
	{
		float vStart[3];
		TR_GetEndPosition(vStart, trace);

		float vBuffer[3];
		GetAngleVectors(vAngles, vBuffer, NULL_VECTOR, NULL_VECTOR);

		pOrigin[0] = vStart[0] + (vBuffer[0] * -distance);
		pOrigin[1] = vStart[1] + (vBuffer[1] * -distance);
		pOrigin[2] = vStart[2] + (vBuffer[2] * -distance);
	}

	delete trace;
	return bReturn;
}

public bool TraceEntityFilterPlayer(int entity, int contentsMask, any data)
{
	return entity > MaxClients || !entity;
}

public bool TraceEntityFilterNone(int entity, int contentsMask, any data)
{
	return entity != data;
}

stock void CreatePointGlow(float origin[3], float time = 30.0, float size = 0.5, int brightness = 50)
{
	TE_SetupGlowSprite(origin, g_GlowSprite, time, size, brightness);
	TE_SendToAll();
}

int FindEntityByName(const char[] name, const char[] classname = "*")
{
	int entity = -1; char temp[256];
	while ((entity = FindEntityByClassname(entity, classname)) != -1)
	{
		GetEntPropString(entity, Prop_Data, "m_iName", temp, sizeof(temp));
		
		if (StrEqual(temp, name, false))
			return entity;
	}
	
	return entity;
}

void GetAbsBoundingBox(int ent, float mins[3], float maxs[3], bool half = false)
{
    float origin[3];

    GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", origin);
    GetEntPropVector(ent, Prop_Data, "m_vecMins", mins);
    GetEntPropVector(ent, Prop_Data, "m_vecMaxs", maxs);

    mins[0] += origin[0];
    mins[1] += origin[1];
    mins[2] += origin[2];
    maxs[0] += origin[0];
    maxs[1] += origin[1];

    if (!half)
        maxs[2] += origin[2];
    else
        maxs[2] = mins[2];
}

void Effect_DrawBeamBoxToClient(int client, const float bottomCorner[3], const float upperCorner[3], int modelIndex, int haloIndex, int startFrame = 0, int frameRate = 30, float life = 5.0, float width = 5.0, float endWidth = 5.0, int fadeLength = 2, float amplitude = 1.0, const color[4] =  { 255, 0, 0, 255 }, int speed = 0)
{
	int clients[1]; clients[0] = client;
	Effect_DrawBeamBox(clients, 1, bottomCorner, upperCorner, modelIndex, haloIndex, startFrame, frameRate, life, width, endWidth, fadeLength, amplitude, color, speed);
}

void Effect_DrawBeamBox(int[] clients, int numClients, const float bottomCorner[3], const float upperCorner[3], int modelIndex, int haloIndex, int startFrame = 0, int frameRate = 30, float life = 5.0, float width = 5.0, float endWidth = 5.0, int fadeLength = 2, float amplitude = 1.0, const color[4] =  { 255, 0, 0, 255 }, int speed = 0)
{
	float corners[8][3];

	for (int i = 0; i < 4; i++)
	{
		CopyArrayToArray(bottomCorner, corners[i], 3);
		CopyArrayToArray(upperCorner, corners[i + 4], 3);
	}

	corners[1][0] = upperCorner[0];
	corners[2][0] = upperCorner[0];
	corners[2][1] = upperCorner[1];
	corners[3][1] = upperCorner[1];
	corners[4][0] = bottomCorner[0];
	corners[4][1] = bottomCorner[1];
	corners[5][1] = bottomCorner[1];
	corners[7][0] = bottomCorner[0];

	for (int i = 0; i < 4; i++)
	{
		int j = (i == 3 ? 0 : i + 1);
		TE_SetupBeamPoints(corners[i], corners[j], modelIndex, haloIndex, startFrame, frameRate, life, width, endWidth, fadeLength, amplitude, color, speed);
		TE_Send(clients, numClients);
	}

	for (int i = 4; i < 8; i++)
	{
		int j = (i == 7 ? 4 : i + 1);
		TE_SetupBeamPoints(corners[i], corners[j], modelIndex, haloIndex, startFrame, frameRate, life, width, endWidth, fadeLength, amplitude, color, speed);
		TE_Send(clients, numClients);
	}

	for (int i = 0; i < 4; i++)
	{
		TE_SetupBeamPoints(corners[i], corners[i + 4], modelIndex, haloIndex, startFrame, frameRate, life, width, endWidth, fadeLength, amplitude, color, speed);
		TE_Send(clients, numClients);
	}
}

void CopyArrayToArray(const any[] array, any[] newArray, int size)
{
	for (int i = 0; i < size; i++)
		newArray[i] = array[i];
}

public Action Command_Start(int client, int args)
{
	int count;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayerAlive(i))
			count++;
	
	if (count < 3)
	{
		CPrintToChat(client, "You cannot manually start the match unless there's three available players.");
		EmitGameSoundToClient(client, "Player.DenyWeaponSelection");
		return Plugin_Handled;
	}

	CPrintToChatAll("{azure}%N {honeydew}has started the match.", client);
	CreateTeamTimer(10, 90, true);

	return Plugin_Handled;
}

public void OnSetupStart(const char[] output, int caller, int activator, float delay)
{
	convar_AllTalk.BoolValue = true;
}

public void OnSetupFinished(const char[] output, int caller, int activator, float delay)
{
	StartMatch();
}

void StartMatch()
{
	convar_AllTalk.BoolValue = false;

	if (GameRules_GetProp("m_bInWaitingForPlayers"))
		ServerCommand("mp_waitingforplayers_cancel 1");

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && TF2_GetClientTeam(i) == TFTeam_Red)
			TF2_ChangeClientTeam_Alive(i, TFTeam_Blue);
	
	g_Match.lobbytime = 0;
	StopTimer(g_Match.lobbytimer);

	g_Match.spawnertimer = GetRandomFloat(20.0, 25.0);
	StopTimer(g_Match.spawner);
	g_Match.spawner = CreateTimer(g_Match.spawnertimer, Timer_SpawnNPCs, _, TIMER_FLAG_NO_MAPCHANGE);
	TriggerTimer(g_Match.spawner, true);

	InitMatch();
}

void InitMatch()
{
	g_Match.lockdowntime = -1;

	g_Match.matchstate = STATE_PLAYING;
	PrintHintTextToAll("Match has started.");

	g_Match.totaltasks = 0;
	g_Match.totalshots = 0;
	
	int count = TF2_GetTeamClientCount(TFTeam_Blue);
	int total = TF2_GetTeamClientCount(TFTeam_Red);
	int balance = RoundToFloor(count * convar_TeamBalance.FloatValue);

	if (total < balance)
	{
		balance -= total;

		int moved; int failsafe; int client;
		while (moved < balance && failsafe < MaxClients)
		{
			if ((client = FindAssassinToMove()) != -1)
			{
				TF2_ChangeClientTeam(client, TFTeam_Red);
				TF2_RespawnPlayer(client);
				g_Player[client].queuepoints = 0;
				SaveQueuePoints(client);
				moved++;
			}
			else
				failsafe++;
		}
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		
		if (TF2_GetClientTeam(i) == TFTeam_Blue)
		{
			g_Player[i].queuepoints++;
			SaveQueuePoints(i);
		}
		
		if (!IsPlayerAlive(i))
			TF2_RespawnPlayer(i);
		
		TF2_RegeneratePlayer(i);
	}

	CreateTimer(0.2, Timer_PostStart, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_PostStart(Handle timer)
{
	int spy = FindSpy();

	if (spy == -1)
	{
		g_Match.matchstate = STATE_LOBBY;
		CPrintToChatAll("Aborting starting match, couldn't find a spy.");
		return Plugin_Stop;
	}
	
	g_Player[spy].isspy = true;
	PrintCenterText(spy, "YOU ARE THE SPY!");
	EmitSoundToClient(spy, "coach/coach_look_here.wav");

	if (IsValidEntity(g_Player[spy].glowent))
	{
		int color[4];
		color[0] = 0;
		color[1] = 255;
		color[2] = 0;
		color[3] = 255;
		
		SetVariantColor(color);
		AcceptEntityInput(g_Player[spy].glowent, "SetGlowColor");
	}

	g_Match.spytask = GetRandomInt(0, g_TotalTasks - 1);
	CPrintToChat(spy, "Priority Task: {aqua}%s {honeydew}(Do this task the most to win the round)", g_Tasks[g_Match.spytask].name);

	g_Match.spyhasdonetask = false;
	StopTimer(g_Match.unlocksnipers);
	g_Match.unlocksnipers = CreateTimer(30.0, Timer_UnlockSnipers, _, TIMER_FLAG_NO_MAPCHANGE);
	CPrintToChat(spy, "You must wait until a spy does a priority task or 30 seconds to fire.");

	int benefactor = -1;

	if (TF2_GetTeamClientCount(TFTeam_Blue) > 4)
		benefactor = FindBenefactor();

	if (benefactor != -1)
	{
		g_Player[benefactor].isbenefactor = true;
		PrintCenterText(benefactor, "YOU ARE A BENEFACTOR!");
		EmitSoundToClient(benefactor, "coach/coach_look_here.wav");

		if (IsValidEntity(g_Player[benefactor].glowent))
		{
			int color[4];
			color[0] = 0;
			color[1] = 0;
			color[2] = 255;
			color[3] = 255;
			
			SetVariantColor(color);
			AcceptEntityInput(g_Player[benefactor].glowent, "SetGlowColor");
		}
	}
	
	for (int i = 1; i <= MaxClients; i++)
	{
		g_Player[i].lastrefilled = -1;

		if (!IsClientInGame(i))
			continue;
		
		if (!IsPlayerAlive(i) || TF2_GetClientTeam(i) == TFTeam_Blue)
			TF2_RespawnPlayer(i);

		switch (TF2_GetClientTeam(i))
		{
			case TFTeam_Red:
			{
				CPrintToChat(i, "Hunt out the spy and assassinate them! You have a limited amount of chances, use them wisely!");
				CPrintToChat(i, "Keep in mind that benefactors can fake you out!");

				int weapon;
				for (int slot = 0; slot < 3; slot++)
					if ((weapon = GetPlayerWeaponSlot(i, slot)) != -1)
						SetWeaponAmmo(i, weapon, 1);
				
				SetEntPropFloat(i, Prop_Send, "m_flNextAttack", GetGameTime() + 99999.0);
				PrintCenterText(i, "You can take your 1st shot in 15 seconds...");
				CreateTimer(15.0, Timer_ShotAllowed, GetClientUserId(i), TIMER_FLAG_NO_MAPCHANGE);
			}

			case TFTeam_Blue:
			{
				CPrintToChat(i, "{azure}%N {honeydew}has been chosen as the Spy, protect them at all costs by doing basic tasks!", spy);

				if (benefactor != -1)
					CPrintToChat(i, "{ancient}%N {honeydew}is a benefactor!", benefactor);
				
				g_Player[i].requiredtasks.Clear();

				for (int x = 0; x < convar_GivenTasks.IntValue; x++)
					AddTask(i, GetRandomInt(0, g_TotalTasks - 1));
				
				ShowTasksPanel(i);
			}
		}

		UpdateHud(i);
	}

	convar_RespawnWaveTime.IntValue = 99999;

	g_Match.givetasks = GetRandomInt(60, 80);
	StopTimer(g_Match.givetaskstimer);
	g_Match.givetaskstimer = CreateTimer(1.0, Timer_GiveTasksTick, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Stop;
}

public Action Timer_UnlockSnipers(Handle timer)
{
	g_Match.spyhasdonetask = true;
	g_Match.unlocksnipers = null;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsPlayerAlive(i) && TF2_GetClientTeam(i) == TFTeam_Red)
		{
			CPrintToChat(i, "The spy hasn't done a task, you can now shoot.");
			EmitSoundToClient(i, "coach/coach_go_here.wav");
		}
	}
}

public Action Timer_ShotAllowed(Handle timer, any data)
{
	int client;
	if ((client = GetClientOfUserId(data)) > 0 && IsClientInGame(client) && IsPlayerAlive(client) && TF2_GetClientTeam(client) == TFTeam_Red)
	{
		PrintCenterText(client, "You may take your 1st shot!");
		SetEntPropFloat(client, Prop_Send, "m_flNextAttack", GetGameTime());
	}
}

int TF2_GetTeamClientCount(TFTeam team)
{
	int value = 0;

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && TF2_GetClientTeam(i) == team)
			value++;

	return value;
}

int FindAssassinToMove()
{
	ArrayList queue = new ArrayList();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || TF2_GetClientTeam(i) != TFTeam_Blue)
			continue;
		
		queue.Push(i);
	}

	if (queue.Length < 1)
	{
		delete queue;
		return -1;
	}

	SortADTArrayCustom(queue, OnSortQueue);
	int client = queue.Get(0);
	delete queue;

	return client;
}

public int OnSortQueue(int index1, int index2, Handle array, Handle hndl)
{
	int client1 = GetArrayCell(array, index1);
	int client2 = GetArrayCell(array, index2);
	
	return g_Player[client2].queuepoints - g_Player[client1].queuepoints;
}

public Action Timer_GiveTasksTick(Handle timer)
{
	g_Match.givetasks--;

	if (g_Match.givetasks > 0)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i))
				continue;
			
			PrintHintText(i, "Next tasks in: %i", g_Match.givetasks);
			StopSound(i, SNDCHAN_STATIC, "UI/hint.wav");
		}

		return Plugin_Continue;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsPlayerAlive(i) && TF2_GetClientTeam(i) == TFTeam_Blue)
		{
			g_Player[i].requiredtasks.Clear();

			for (int x = 0; x < convar_GivenTasks.IntValue; x++)
				AddTask(i, GetRandomInt(0, g_TotalTasks - 1));
			
			ShowTasksPanel(i);
		}
	}

	g_Match.givetasks = GetRandomInt(60, 80);
	return Plugin_Continue;
}

void ShowTasksPanel(int client)
{
	Panel panel = new Panel();
	panel.SetTitle("Available Tasks:");

	char sDisplay[128];
	FormatEx(sDisplay, sizeof(sDisplay), "Priority Task: %s", g_Tasks[g_Match.spytask].name);
	panel.DrawText(sDisplay);

	for (int i = 0; i < g_Player[client].requiredtasks.Length; i++)
	{
		int task = g_Player[client].requiredtasks.Get(i);
		FormatEx(sDisplay, sizeof(sDisplay), "Task %i: %s", i + 1, g_Tasks[task].name);
		panel.DrawText(sDisplay);
	}

	panel.Send(client, MenuAction_Void, MENU_TIME_FOREVER);
	delete panel;
}

public int MenuAction_Void(Menu menu, MenuAction action, int param1, int param2)
{

}

int GetWeaponAmmo(int client, int weapon)
{
	int iAmmoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	
	if (iAmmoType != -1)
		return GetEntProp(client, Prop_Data, "m_iAmmo", _, iAmmoType);
	
	return 0;
}

void SetWeaponAmmo(int client, int weapon, int ammo)
{
	int iAmmoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	
	if (iAmmoType != -1)
		SetEntProp(client, Prop_Data, "m_iAmmo", ammo, _, iAmmoType);
}

int FindSpy()
{
	int[] clients = new int[MaxClients];
	int amount;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || TF2_GetClientTeam(i) != TFTeam_Blue)
			continue;

		clients[amount++] = i;
	}

	if (amount == 0)
		return -1;

	return clients[GetRandomInt(0, amount - 1)];
}

int FindBenefactor()
{
	int[] clients = new int[MaxClients];
	int amount;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || TF2_GetClientTeam(i) != TFTeam_Blue || g_Player[i].isspy)
			continue;

		clients[amount++] = i;
	}

	if (amount == 0)
		return -1;

	return clients[GetRandomInt(0, amount - 1)];
}

bool StopTimer(Handle& timer)
{
	if (timer != null)
	{
		KillTimer(timer);
		timer = null;
		return true;
	}
	
	return false;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "trigger_multiple", false))
	{
		SDKHook(entity, SDKHook_StartTouch, OnTouchTriggerStart);
		SDKHook(entity, SDKHook_EndTouch, OnTouchTriggerEnd);
	}

	if (StrContains(classname, "tf_ammo_pack", false) != -1 || StrEqual(classname, "tf_dropped_weapon", false) || StrEqual(classname, "item_currencypack_custom", false))
		SDKHook(entity, SDKHook_Spawn, OnBlockSpawn);
	
	if (StrEqual(classname, "func_button", false))
		SDKHook(entity, SDKHook_OnTakeDamage, OnButtonUse);
	
	if (StrEqual(classname, "team_round_timer", false))
	{
		SDKHook(entity, SDKHook_SpawnPost, OnTimerSpawnPost);

		if (g_Late)
			OnTimerSpawnPost(entity);
	}
}

public Action OnButtonUse(int victim, int& attacker, int& inflictor, float& damage, int& damagetype)
{
	char sName[64];
	GetEntPropString(victim, Prop_Data, "m_iName", sName, sizeof(sName));

	int time = GetTime();

	if (StrEqual(sName, "lockdown", false))
	{
		if (g_Match.matchstate != STATE_PLAYING)
			return Plugin_Stop;
		
		if (g_Match.lockdowntime > time)
		{
			EmitGameSoundToClient(attacker, "Player.DenyWeaponSelection");
			CPrintToChat(attacker, "You must wait another {azure}%i {honeydew} seconds to start another lockdown.", g_Match.lockdowntime - time);
			return Plugin_Stop;
		}

		g_Match.lockdowntime = time + 300;
		EmitSoundToAll("ambient/alarms/doomsday_lift_alarm.wav", victim);
	}

	return Plugin_Continue;
}

public void OnGameFrame()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		
		if (IsPlayerAlive(i) && TF2_GetClientTeam(i) == TFTeam_Blue && GetEntPropFloat(i, Prop_Send, "m_flMaxspeed") != 300.0)
			SetEntPropFloat(i, Prop_Send, "m_flMaxspeed", 300.0);
	}
}

public Action OnBlockSpawn(int entity)
{
	return Plugin_Stop;
}

public Action OnTouchTriggerStart(int entity, int other)
{
	if (other < 1 || other > MaxClients)
		return;
	
	char sName[64];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	int time = GetTime();

	if (StrEqual(sName, "refill_mag", false) && TF2_GetClientTeam(other) == TFTeam_Red && g_Match.matchstate == STATE_PLAYING)
	{
		int weapon = GetEntPropEnt(other, Prop_Send, "m_hActiveWeapon");

		if (GetWeaponAmmo(other, weapon) > 0)
		{
			CPrintToChat(other, "Your sniper is already full.");
			EmitGameSoundToClient(other, "Player.DenyWeaponSelection");
			return;
		}

		if (g_Player[other].lastrefilled > time)
		{
			CPrintToChat(other, "You must wait {azure}%i {honeydew}seconds to refill your sniper.", g_Player[other].lastrefilled - time);
			EmitGameSoundToClient(other, "Player.DenyWeaponSelection");
			return;
		}

		g_Player[other].lastrefilled = time + 60;
		EmitGameSoundToClient(other, "AmmoPack.Touch");
		SetWeaponAmmo(other, weapon, 1);
		
		return;
	}
	else if (StrEqual(sName, "changing_room", false))
	{
		if (g_Player[other].lastchangedclass > time)
		{
			CPrintToChat(other, "You must wait {azure}%i {honeydew}seconds to change your class again.", g_Player[other].lastchangedclass - time);
			EmitGameSoundToClient(other, "Player.DenyWeaponSelection");
			return;
		}

		if (TF2_GetClientTeam(other) == TFTeam_Red)
		{
			CPrintToChat(other, "You must be on the {azure}BLUE {honeydew}team to change your class here.");
			EmitGameSoundToClient(other, "Player.DenyWeaponSelection");
			return;
		}
		
		g_Player[other].changeclass = true;
		ShowVGUIPanel(other, GetClientTeam(other) == 3 ? "class_blue" : "class_red");
		return;
	}

	int task = GetTaskByName(sName);

	if (task == -1 || TF2_GetClientTeam(other) != TFTeam_Blue)
		return;
	
	g_Player[other].neartask = task;
	
	if (HasTask(other, task))
		CPrintToChat(other, "You have this task, press {beige}MEDIC! {honeydew}to start this task.");
}

public Action OnTouchTriggerEnd(int entity, int other)
{
	if (other < 1 || other > MaxClients)
		return;
	
	char sName[64];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	if (StrEqual(sName, "changing_room", false))
	{
		g_Player[other].changeclass = false;
		return;
	}

	int task = GetTaskByName(sName);

	if (task == -1 || g_Player[other].neartask != task || TF2_GetClientTeam(other) != TFTeam_Blue)
		return;
	
	g_Player[other].neartask = -1;
}

bool PushMenuInt(Menu menu, const char[] id, int value)
{
	if (menu == null || strlen(id) == 0)
		return false;
	
	char sBuffer[128];
	IntToString(value, sBuffer, sizeof(sBuffer));
	return menu.AddItem(id, sBuffer, ITEMDRAW_IGNORE);
}

int GetMenuInt(Menu menu, const char[] id, int defaultvalue = 0)
{
	if (menu == null || strlen(id) == 0)
		return defaultvalue;
	
	char info[128]; char data[128];
	for (int i = 0; i < menu.ItemCount; i++)
		if (menu.GetItem(i, info, sizeof(info), _, data, sizeof(data)) && StrEqual(info, id))
			return StringToInt(data);
	
	return defaultvalue;
}

int GetTaskByName(const char[] task)
{
	for (int i = 0; i < g_TotalTasks; i++)
		if (StrEqual(task, g_Tasks[i].trigger, false))
			return i;
	
	return -1;
}

public Action Listener_VoiceMenu(int client, const char[] command, int argc)
{
	char sVoice[32];
	GetCmdArg(1, sVoice, sizeof(sVoice));

	char sVoice2[32];
	GetCmdArg(2, sVoice2, sizeof(sVoice2));
	
	if (!StrEqual(sVoice, "0", false) || !StrEqual(sVoice2, "0", false) || g_Match.matchstate != STATE_PLAYING)
		return Plugin_Continue;
	
	if (TF2_GetClientTeam(client) == TFTeam_Blue)
	{
		if (g_Player[client].neartask != -1 && HasTask(client, g_Player[client].neartask))
		{
			g_Player[client].tasktimer = 10.0;
			StopTimer(g_Player[client].doingtask);
			g_Player[client].doingtask = CreateTimer(0.1, Timer_DoingTask, client, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		}

		int time = GetTime();

		if (g_Player[client].isbenefactor && g_Player[client].benefactornoises <= time)
		{
			g_Player[client].benefactornoises = time + 10;
			EmitSoundToAll("coach/coach_look_here.wav");
		}

		return Plugin_Stop;
	}
	else if (TF2_GetClientTeam(client) == TFTeam_Red)
	{
		int target = GetClientAimTarget(client, true);

		if (target == -1 || g_Player[target].ismarked)
			return Plugin_Stop;
		
		SpeakResponseConcept(client, "TLK_PLAYER_POSITIVE");
		SpeakResponseConcept(target, "TLK_PLAYER_NEGATIVE");
		
		if (IsValidEntity(g_Player[target].glowent))
		{
			int color[4];
			color[0] = 0;
			color[1] = 0;
			color[2] = 255;
			color[3] = 255;
			
			SetVariantColor(color);
			AcceptEntityInput(g_Player[target].glowent, "SetGlowColor");

			g_Player[target].ismarked = true;
			CreateTimer(30.0, Timer_ResetColor, target);
		}

		return Plugin_Stop;
	}

	return Plugin_Continue;
}

public Action Timer_ResetColor(Handle timer, any data)
{
	int client = data;

	if (IsValidEntity(g_Player[client].glowent))
	{
		int color[4];
		color[0] = 255;
		color[1] = 255;
		color[2] = 255;
		color[3] = 255;
		
		SetVariantColor(color);
		AcceptEntityInput(g_Player[client].glowent, "SetGlowColor");

		g_Player[client].ismarked = false;
	}
}

public Action Timer_DoingTask(Handle timer, any data)
{
	int client = data;

	g_Player[client].tasktimer -= 0.1;

	if (g_Player[client].neartask == -1)
	{
		g_Player[client].doingtask = null;
		return Plugin_Stop;
	}

	if (g_Player[client].tasktimer > 0.0)
	{
		PrintCenterText(client, "Doing Task... %i", RoundFloat(g_Player[client].tasktimer));
		return Plugin_Continue;
	}

	CompleteTask(client, g_Player[client].neartask);
	g_Player[client].neartask = -1;

	g_Player[client].doingtask = null;
	return Plugin_Stop;
}
//int g_LastTime[MAXPLAYERS + 1] = {-1, ...};
public MRESReturn OnMyWeaponFired(int client, Handle hReturn, Handle hParams)
{
	if (client < 1 || client > MaxClients || !IsValidEntity(client) || !IsPlayerAlive(client))
		return MRES_Ignored;
	
	if (TF2_GetClientTeam(client) == TFTeam_Red)
	{
		g_Match.totalshots++;
		SpeakResponseConcept(client, "TLK_FIREWEAPON");

		for (int i = 1; i <= MaxClients; i++)
			if (IsClientInGame(i) && TF2_GetClientTeam(i) == TFTeam_Red)
				UpdateHud(i);
		
		if (g_Match.totalshots >= GetMaxShots())
		{
			CreateTimer(0.5, Timer_WeaponFirePost, _, TIMER_FLAG_NO_MAPCHANGE);
			return MRES_Ignored;
		}

		if (g_Player[client].lastrefilled != -1)
		{
			g_Player[client].lastrefilled = GetTime() + 10;

			int entity = -1; float origin[3]; char sName[32];
			while ((entity = FindEntityByClassname(entity, "trigger_multiple")) != -1)
			{
				GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

				if (!StrEqual(sName, "refill_mag", false))
					continue;

				GetEntPropVector(entity, Prop_Send, "m_vecAbsOrigin", origin);
				origin[2] += 10.0;
				TF2_CreateAnnotation(client, origin, "Ammo Crate");
			}
		}
	}
	
	return MRES_Ignored;
}

public Action Timer_WeaponFirePost(Handle timer)
{
	if (g_Match.matchstate != STATE_PLAYING)
		return Plugin_Stop;
	
	CPrintToChatAll("Red team has ran out of ammunition, Blue wins the round.");
	TF2_ForceWin(TFTeam_Blue);

	return Plugin_Stop;
}

int GetMaxShots()
{
	int shots;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayerAlive(i) && TF2_GetClientTeam(i) == TFTeam_Red)
			shots += 2;
	
	return shots;
}

public Action OnClientCommand(int client, int args)
{
	char sCommand[32];
	GetCmdArg(0, sCommand, sizeof(sCommand));

	if (StrEqual(sCommand, "joinclass", false))
	{
		char sValue[32];
		GetCmdArg(1, sValue, sizeof(sValue));
		//PrintToChat(client, "value: %s", sValue);

		if (g_Player[client].changeclass)
		{
			switch (TF2_GetClientTeam(client))
			{
				case TFTeam_Red:
				{
					CPrintToChat(client, "You must be on the {azure}BLUE {honeydew}team to change your class here.");
					EmitGameSoundToClient(client, "Player.DenyWeaponSelection");
					return Plugin_Stop;
				}

				case TFTeam_Blue:
				{
					if (StrEqual(sValue, "spy", false) || StrEqual(sValue, "sniper", false))
					{
						CPrintToChat(client, "You are not allowed to change your class to {azure}%s {honeydew}.", sValue);
						EmitGameSoundToClient(client, "Player.DenyWeaponSelection");
						return Plugin_Stop;
					}
					
					TFClassType class = TF2_GetClass(sValue);
					TF2_SetPlayerClass(client, class, false, true);
					TF2_RegeneratePlayer(client);
					OnSpawn(client);

					g_Player[client].lastchangedclass = GetTime() + 30;
					CPrintToChat(client, "You have switched your class to {azure}%s{honeydew}.", sValue);
					g_Player[client].changeclass = false;
				}
			}

			return Plugin_Stop;
		}
	}

	if (g_Match.matchstate == STATE_PLAYING && TF2_GetClientTeam(client) > TFTeam_Spectator && (StrEqual(sCommand, "jointeam", false) || StrEqual(sCommand, "joinclass", false)))
		return Plugin_Stop;
	
	/*if (StrEqual(sCommand, "eureka_teleport", false))
	{
		CPrintToChat(client, "You are not allowed to use the Eureka Effect.");
		return Plugin_Stop;
	}*/
	
	return Plugin_Continue;
}

public void Event_OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	convar_RespawnWaveTime.IntValue = 10;
	convar_AutoTeamBalance.IntValue = 0;
	convar_TeamBalanceLimit.IntValue = 0;
	convar_AutoScramble.IntValue = 0;

	bool available;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayerAlive(i))
			available = true;
	
	if (available)
		g_Match.matchstate = STATE_LOBBY;
}

public void Event_OnRoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	convar_AllTalk.BoolValue = true;
	g_Match.matchstate = STATE_HIBERNATION;

	g_Match.lobbytime = 0;
	StopTimer(g_Match.lobbytimer);

	StopTimer(g_Match.unlocksnipers);

	g_Match.spawnertimer = 0.0;
	StopTimer(g_Match.spawner);

	for (int i = 1; i <= MaxClients; i++)
	{
		g_Player[i].isspy = false;
		g_Player[i].isbenefactor = false;

		g_Player[i].lastrefilled = -1;

		if (g_Player[i].requiredtasks != null)
			g_Player[i].requiredtasks.Clear();
		g_Player[i].neartask = -1;

		if (IsClientInGame(i) && IsPlayerAlive(i))
		{
			if (TF2_GetClientTeam(i) == TFTeam_Red)
			{
				if (TF2_IsPlayerInCondition(i, TFCond_Zoomed))
					TF2_RemoveCondition(i, TFCond_Zoomed);
				
				if (TF2_IsPlayerInCondition(i, TFCond_Slowed))
					TF2_RemoveCondition(i, TFCond_Slowed);
			}

			if (g_Player[i].glowent > 0 && IsValidEntity(g_Player[i].glowent))
			{
				RemoveEntity(g_Player[i].glowent);
				g_Player[i].glowent = -1;
			}
		}
	}

	g_Match.totaltasks = 0;
	g_Match.totalshots = 0;

	g_Match.givetasks = 0;
	StopTimer(g_Match.givetaskstimer);

	convar_RespawnWaveTime.IntValue = 10;
}

int TF2_CreateGlow(const char[] name, int target, int color[4] = {255, 255, 255, 255})
{
	char sClassname[64];
	GetEntityClassname(target, sClassname, sizeof(sClassname));

	char sTarget[128];
	Format(sTarget, sizeof(sTarget), "%s%i", sClassname, target);
	DispatchKeyValue(target, "targetname", sTarget);

	int glow = CreateEntityByName("tf_glow");

	if (IsValidEntity(glow))
	{
		char sGlow[64];
		Format(sGlow, sizeof(sGlow), "%i %i %i %i", color[0], color[1], color[2], color[3]);

		DispatchKeyValue(glow, "targetname", name);
		DispatchKeyValue(glow, "target", sTarget);
		DispatchKeyValue(glow, "Mode", "1"); //Mode is currently broken.
		DispatchKeyValue(glow, "GlowColor", sGlow);
		DispatchSpawn(glow);
		
		SetVariantString("!activator");
		AcceptEntityInput(glow, "SetParent", target, glow);

		AcceptEntityInput(glow, "Enable");
	}

	return glow;
}

void CreateTeamTimer(int setup_time = 60, int round_time = 90, bool countdown = true)
{
	int entity = FindEntityByClassname(-1, "team_round_timer");

	if (!IsValidEntity(entity))
		entity = CreateEntityByName("team_round_timer");
	
	char sSetup[32];
	IntToString(setup_time + 1, sSetup, sizeof(sSetup));
	
	char sRound[32];
	IntToString(round_time + 1, sRound, sizeof(sRound));
	
	DispatchKeyValue(entity, "reset_time", "1");
	DispatchKeyValue(entity, "show_time_remaining", "1");
	DispatchKeyValue(entity, "setup_length", sSetup);
	DispatchKeyValue(entity, "timer_length", sRound);
	DispatchKeyValue(entity, "auto_countdown", countdown ? "1" : "0");
	DispatchSpawn(entity);

	AcceptEntityInput(entity, "Resume");

	SetVariantInt(1);
	AcceptEntityInput(entity, "ShowInHUD");
}

void PauseTF2Timer()
{
	if (IsTimerPaused())
		return;
	
	int entity = FindEntityByClassname(-1, "team_round_timer");

	if (!IsValidEntity(entity))
		entity = CreateEntityByName("team_round_timer");
	
	AcceptEntityInput(entity, "Pause");
}

void UnpauseTF2Timer()
{
	if (!IsTimerPaused())
		return;
	
	int entity = FindEntityByClassname(-1, "team_round_timer");

	if (!IsValidEntity(entity))
		entity = CreateEntityByName("team_round_timer");
	
	AcceptEntityInput(entity, "Resume");
}

bool IsTimerPaused()
{
	int entity = FindEntityByClassname(-1, "team_round_timer");

	if (!IsValidEntity(entity))
		return false;
	
	return view_as<bool>(GetEntProp(entity, Prop_Send, "m_bTimerPaused"));
}

void AddTime(int time = 30)
{
	if (IsTimerPaused())
		return;
	
	int entity = FindEntityByClassname(-1, "team_round_timer");

	if (!IsValidEntity(entity))
		entity = CreateEntityByName("team_round_timer");
	
	SetVariantInt(time);
	AcceptEntityInput(entity, "AddTime");
}

void TF2Attrib_ApplyMoveSpeedBonus(int client, float value)
{
	TF2Attrib_SetByName(client, "move speed bonus", 1.0 + value);
	TF2_AddCondition(client, TFCond_SpeedBuffAlly, 0.0);
}

void TF2Attrib_RemoveMoveSpeedBonus(int client)
{
	TF2Attrib_RemoveByName(client, "move speed bonus");
	TF2_AddCondition(client, TFCond_SpeedBuffAlly, 0.0);
}

void InitLobby()
{
	g_Match.matchstate = STATE_LOBBY;
	CreateTeamTimer(60, 90, true);

	StopTimer(g_Match.lobbytimer);
	g_Match.lobbytime = 120;
	g_Match.lobbytimer = CreateTimer(1.0, Timer_StartMatch, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_StartMatch(Handle timer)
{
	if (GameRules_GetProp("m_bInWaitingForPlayers"))
		return Plugin_Continue;
	
	int count;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayerAlive(i))
			count++;
	
	if (count < 3)
	{
		if (!IsTimerPaused() && !g_Match.ispaused)
		{
			PauseTF2Timer();
			UpdateHudAll();
		}

		return Plugin_Continue;
	}
	else
	{
		if (IsTimerPaused() && !g_Match.ispaused)
		{
			UnpauseTF2Timer();
			UpdateHudAll();
		}
	}
	
	g_Match.lobbytime--;

	if (g_Match.lobbytime > 0)
		return Plugin_Continue;

	g_Match.lobbytime = 0;
	g_Match.lobbytimer = null;

	return Plugin_Stop;
}

public void TF2_OnWaitingForPlayersEnd()
{
	CreateTimer(0.2, Timer_Init);
}

public Action Timer_Init(Handle timer)
{
	InitLobby();
}

public Action Command_QueuePoints(int client, int args)
{
	CPrintToChat(client, "You currently have {azure}%i {honeydew}queue points.", g_Player[client].queuepoints);

	int total;
	int position = g_Player[client].GetQueuePosition(total);

	CPrintToChat(client, "You are currently {azure}%i/%i {honeydew}in line for assassin.", position, total);

	return Plugin_Handled;
}

public Action Command_SetQueuePoints(int client, int args)
{
	int target = client;

	if (args > 0)
	{
		char sTarget[MAX_TARGET_LENGTH];
		GetCmdArg(1, sTarget, sizeof(sTarget));
		target = FindTarget(client, sTarget, false, false);

		if (target == -1)
		{
			CPrintToChat(client, "Target {azure}%s {honeydew}not found, please try again.", sTarget);
			return Plugin_Handled;
		}
	}

	char sPoints[32];
	GetCmdArg(args > 1 ? 2 : 1, sPoints, sizeof(sPoints));
	int points = StringToInt(sPoints);

	g_Player[target].queuepoints = points;
	SaveQueuePoints(target);

	UpdateHud(target);

	if (client == target)
		CPrintToChat(client, "You have set your own queue points to {azure}%i{honeydew}.", g_Player[target].queuepoints);
	else
	{
		CPrintToChat(client, "You have set {azure}%N{honeydew}'s queue points to {azure}%i{honeydew}.", target, g_Player[target].queuepoints);
		CPrintToChat(target, "{azure}%N {honeydew}has set your queue points by {azure}%i{honeydew}.", client, g_Player[target].queuepoints);
	}

	return Plugin_Handled;
}

bool TF2_ChangeClientTeam_Alive(int client, TFTeam team)
{
	if (client == 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client) || team < TFTeam_Red || team > TFTeam_Blue)
		return false;

	int lifestate = GetEntProp(client, Prop_Send, "m_lifeState");
	SetEntProp(client, Prop_Send, "m_lifeState", 2);
	ChangeClientTeam(client, view_as<int>(team));
	SetEntProp(client, Prop_Send, "m_lifeState", lifestate);
	
	return true;
}

void SpeakResponseConcept(int client, const char[] concept, const char[] context = "", const char[] class = "")
{
	bool hascontext;

	//For class specific context basically.
	if (strlen(context) > 0)
	{
		SetVariantString(context);
		AcceptEntityInput(client, "AddContext");

		hascontext = true;
	}

	//dominations require you add more context to them for certain things.
	if (strlen(class) > 0)
	{
		char sClass[64];
		FormatEx(sClass, sizeof(sClass), "victimclass:%s", class);
		SetVariantString(sClass);
		AcceptEntityInput(client, "AddContext");

		hascontext = true;
	}

	SetVariantString(concept);
	AcceptEntityInput(client, "SpeakResponseConcept");

	if (hascontext)
		AcceptEntityInput(client, "ClearContext");
}

void TF2_CreateAnnotation(int client, float[3] origin, const char[] text, float lifetime = 10.0, const char[] sound = "vo/null.wav")
{
	if (!IsClientInGame(client))
		return;
	
	Event event = CreateEvent("show_annotation");
		
	if (event == null)
		return;
		
	event.SetFloat("worldPosX", origin[0]);
	event.SetFloat("worldPosY", origin[1]);
	event.SetFloat("worldPosZ", origin[2]);
	event.SetInt("follow_entindex", client);
	event.SetFloat("lifetime", lifetime);
	event.SetInt("id", client + 8750);
	event.SetString("text", text);
	event.SetString("play_sound", sound);
	event.SetString("show_effect", "0");
	event.SetString("show_distance", "0");
	event.Fire(false);
}

public Action Command_Pause(int client, int args)
{
	g_Match.ispaused = true;
	PauseTF2Timer();
	CPrintToChatAll("{azure}%N {honeydew}has paused the timer.", client);
	return Plugin_Handled;
}

public Action Command_Unpause(int client, int args)
{
	g_Match.ispaused = false;
	UnpauseTF2Timer();
	CPrintToChatAll("{azure}%N {honeydew}has resumed the timer.", client);
	return Plugin_Handled;
}

public Action Command_Tasks(int client, int args)
{
	if (TF2_GetClientTeam(client) == TFTeam_Red)
	{
		CPrintToChat(client, "You must be on the Blue team to use this command.");
		return Plugin_Handled;
	}

	ShowTasksPanel(client);
	return Plugin_Handled;
}

public Action Command_SpawnNPC(int client, int args)
{
	SpawnNPC();
	return Plugin_Handled;
}

void SpawnNPC()
{
	int point = GetBotSpawnPoint();

	if (point < 1)
		return;

	float vecOrigin[3];
	GetEntPropVector(point, Prop_Send, "m_vecOrigin", vecOrigin);

	CBaseNPC npc = new CBaseNPC();
	
	if (npc == INVALID_NPC)
		return;
	
	CBaseCombatCharacter npcEntity = CBaseCombatCharacter(npc.GetEntity());
	npcEntity.Spawn();
	npcEntity.Teleport(vecOrigin);
	npcEntity.SetModel(sModels[GetRandomInt(1, 9)]);

	SetEntProp(npcEntity.iEnt, Prop_Send, "m_nSkin",  1);
	
	SDKHook(npcEntity.iEnt, SDKHook_Think, Hook_NPCThink);
	
	npc.flStepSize = 18.0;
	npc.flGravity = 800.0;
	npc.flAcceleration = 4000.0;
	npc.flJumpHeight = 85.0;
	npc.flWalkSpeed = 300.0;
	npc.flRunSpeed = 300.0;
	npc.flDeathDropHeight = 2000.0;

	npc.iHealth = 200;
	npc.iMaxHealth = 200;

	npc.SetBodyMins(view_as<float>({-1.0, -1.0, 0.0}));
	npc.SetBodyMaxs(view_as<float>({1.0, 1.0, 90.0}));
	
	int iSequence = npcEntity.SelectWeightedSequence(ACT_MP_STAND_MELEE);
	if (iSequence != -1)
	{
		npcEntity.ResetSequence(iSequence);
		SetEntPropFloat(npcEntity.iEnt, Prop_Data, "m_flCycle", 0.0);
	}

	EmitSoundToAll("doors/default_locked.wav", npcEntity.iEnt);

	CreateTimer(1.0, Timer_SendToTask, npc.GetEntity());
}

public Action Timer_SendToTask(Handle timer, any data)
{
	int entity = -1;
	if ((entity = EntRefToEntIndex(data)) == -1)
		return;
	
	CBaseNPC npc = TheNPCs.FindNPCByEntIndex(entity);

	if (npc == INVALID_NPC)
		return;

	int task = GetRandomTask();

	if (!IsValidEntity(task))
		return;
	
	g_NPCTask[npc.Index] = task;
	
	float fStart[3], fEnd[3], fMiddle[3];
	GetAbsBoundingBox(task, fStart, fEnd);
	GetMiddleOfABox(fStart, fEnd, fMiddle);

	fMiddle[2] += 10.0;
	pPath[npc.Index].ComputeToPos(npc.GetBot(), fMiddle, 9999999999.0);
	pPath[npc.Index].SetMinLookAheadDistance(300.0);

	CreateTimer(20.0, Timer_NPCLeave, npc.GetEntity(), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_NPCLeave(Handle timer, any data)
{
	int entity = -1;
	if ((entity = EntRefToEntIndex(data)) == -1)
		return;
	
	CBaseNPC npc = TheNPCs.FindNPCByEntIndex(entity);

	if (npc == INVALID_NPC)
		return;
	
	int point = GetBotSpawnPoint();

	if (point < 1)
		return;
	
	float vecOrigin[3];
	GetEntPropVector(point, Prop_Send, "m_vecOrigin", vecOrigin);
	
	g_NPCTask[npc.Index] = 0;

	vecOrigin[2] += 10.0;
	pPath[npc.Index].ComputeToPos(npc.GetBot(), vecOrigin, 9999999999.0);
	pPath[npc.Index].SetMinLookAheadDistance(300.0);

	CreateTimer(20.0, Timer_DestroyNPC, npc.GetEntity(), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DestroyNPC(Handle timer, any data)
{
	int entity = -1;
	if ((entity = EntRefToEntIndex(data)) == -1)
		return;

	EmitSoundToAll("doors/default_locked.wav", entity);
	RemoveEntity(entity);
}

void GetMiddleOfABox(const float vec1[3], const float vec2[3], float buffer[3])
{
	float mid[3];
	MakeVectorFromPoints(vec1, vec2, mid);

	mid[0] /= 2.0;
	mid[1] /= 2.0;
	mid[2] /= 2.0;

	AddVectors(vec1, mid, buffer);
}

int GetRandomTask()
{
	int[] tasks = new int[g_TotalTasks];
	int total;

	int entity = -1; char sName[64];
	while ((entity = FindEntityByClassname(entity, "trigger_multiple")) != -1)
	{
		GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

		if (StrContains(sName, "task_", false) == 0)
			tasks[total++] = entity;
	}

	return tasks[GetRandomInt(0, total - 1)];
}

int GetBotSpawnPoint()
{
	int points[3];
	int total;

	int entity = -1; char sName[64];
	while ((entity = FindEntityByClassname(entity, "info_target")) != -1)
	{
		GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

		if (StrEqual(sName, "bot_spawn_point", false))
			points[total++] = entity;
	}

	return points[GetRandomInt(0, total - 1)];
}

public void Hook_NPCThink(int iEnt)
{
	CBaseNPC npc = TheNPCs.FindNPCByEntIndex(iEnt);
		
	if (npc != INVALID_NPC)
	{
		float vecNPCPos[3], vecNPCAng[3], vecTargetPos[3];
		INextBot bot = npc.GetBot();
		NextBotGroundLocomotion loco = npc.GetLocomotion();
		
		bot.GetPosition(vecNPCPos);
		GetEntPropVector(iEnt, Prop_Data, "m_angAbsRotation", vecNPCAng);
		
		int task = g_NPCTask[npc.Index];

		float fStart[3], fEnd[3];
		GetAbsBoundingBox(task, fStart, fEnd);
		GetMiddleOfABox(fStart, fEnd, vecTargetPos);
				
		CBaseCombatCharacter animationEntity = CBaseCombatCharacter(iEnt);
		
		if (GetVectorDistance(vecNPCPos, vecTargetPos) > 100.0)
			pPath[npc.Index].Update(bot);
		
		loco.Run();
		
		int iSequence = GetEntProp(iEnt, Prop_Send, "m_nSequence");
		
		static int sequence_ilde = -1;
		if (sequence_ilde == -1) sequence_ilde = animationEntity.SelectWeightedSequence(ACT_MP_STAND_MELEE);
		
		static int sequence_air_walk = -1;
		if (sequence_air_walk == -1) sequence_air_walk = animationEntity.SelectWeightedSequence(ACT_MP_JUMP_FLOAT_MELEE);
		
		static int sequence_run = -1;
		if (sequence_run == -1) sequence_run = animationEntity.SelectWeightedSequence(ACT_MP_RUN_MELEE);

		int iPitch = animationEntity.LookupPoseParameter("body_pitch");
		int iYaw = animationEntity.LookupPoseParameter("body_yaw");
		float vecDir[3], vecAng[3], vecNPCCenter[3];
		animationEntity.WorldSpaceCenter(vecNPCCenter);
		SubtractVectors(vecNPCCenter, vecTargetPos, vecDir); 
		NormalizeVector(vecDir, vecDir);
		GetVectorAngles(vecDir, vecAng); 
		
		float flPitch = animationEntity.GetPoseParameter(iPitch);
		float flYaw = animationEntity.GetPoseParameter(iYaw);
		
		vecAng[0] = UTIL_Clamp(UTIL_AngleNormalize(vecAng[0]), -44.0, 89.0);
		animationEntity.SetPoseParameter(iPitch, UTIL_ApproachAngle(vecAng[0], flPitch, 1.0));
		vecAng[1] = UTIL_Clamp(-UTIL_AngleNormalize(UTIL_AngleDiff(UTIL_AngleNormalize(vecAng[1]), UTIL_AngleNormalize(vecNPCAng[1]+180.0))), -44.0,  44.0);
		animationEntity.SetPoseParameter(iYaw, UTIL_ApproachAngle(vecAng[1], flYaw, 1.0));
		
		int iMoveX = animationEntity.LookupPoseParameter("move_x");
		int iMoveY = animationEntity.LookupPoseParameter("move_y");
		
		if ( iMoveX < 0 || iMoveY < 0 )
			return;
		
		float flGroundSpeed = loco.GetGroundSpeed();
		if ( flGroundSpeed != 0.0 )
		{
			if (!(GetEntityFlags(iEnt) & FL_ONGROUND))
			{
				if (iSequence != sequence_air_walk)
					animationEntity.ResetSequence(sequence_air_walk);
			}
			else
			{			
				if (iSequence != sequence_run)
					animationEntity.ResetSequence(sequence_run);
			}
			
			float vecForward[3], vecRight[3], vecUp[3], vecMotion[3];
			animationEntity.GetVectors(vecForward, vecRight, vecUp);
			loco.GetGroundMotionVector(vecMotion);
			float newMoveX = (vecForward[1] * vecMotion[1]) + (vecForward[0] * vecMotion[0]) +  (vecForward[2] * vecMotion[2]);
			float newMoveY = (vecRight[1] * vecMotion[1]) + (vecRight[0] * vecMotion[0]) + (vecRight[2] * vecMotion[2]);
			
			animationEntity.SetPoseParameter(iMoveX, newMoveX);
			animationEntity.SetPoseParameter(iMoveY, newMoveY);
		}
		else
		{
			if (iSequence != sequence_ilde)
				animationEntity.ResetSequence(sequence_ilde);
		}
	}
}

public void OnSQLConnect(Database db, const char[] error, any data)
{
	if (db == null)
		ThrowError("Error while connecting to database: %s", error);
	
	g_Database = db;
	LogMessage("Connected to database successfully.");

	char auth[64];
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientAuthorized(i) && GetClientAuthId(i, AuthId_Steam2, auth, sizeof(auth)))
			OnClientAuthorized(i, auth);
}

public Action Command_Spy(int client, int args)
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && g_Player[i].isspy)
			CPrintToChat(client, "{azure}%N {honeydew}is currently a spy!", i);
	
	return Plugin_Handled;
}

public void OnTimerSpawnPost(int entity)
{
	HookSingleEntityOutput(entity, "OnSetupStart", OnSetupStart);
	HookSingleEntityOutput(entity, "OnSetupFinished", OnSetupFinished);
}

public Action Timer_SpawnNPCs(Handle timer)
{
	for (int i = 0; i < GetRandomInt(2, 3); i++)
		SpawnNPC();

	g_Match.spawnertimer = GetRandomFloat(20.0, 25.0);
	g_Match.spawner = CreateTimer(g_Match.spawnertimer, Timer_SpawnNPCs, _, TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Stop;
}