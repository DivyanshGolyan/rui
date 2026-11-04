//! The Store format step from 51 to 52 (T1b-1): tool records and tool
//! sets (D48, D49) replace each Session's tools_mask, and every Operation
//! is indexed by admission. Its text is pinned (`schema.Migration`):
//! never edit it once 52 ships; a later change is a new step.
//!
//! The tools a 51 Store names are the two built-ins, as their records read
//! at 52: their texts, set digests and content digests are literals here,
//! since SQL cannot hash. Each distinct tools_mask becomes the set whose
//! id is the mask plus one, with only the records and content it uses.

pub const sqlite = [_][:0]const u8{
    \\CREATE TABLE tool_record(
    \\ tool_record_id INTEGER PRIMARY KEY NOT NULL CHECK(tool_record_id>0),
    \\ name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 64 AND (name NOT GLOB '*[^A-Za-z0-9_-]*' AND length(name)=length(CAST(name AS BLOB)))),
    \\ owner TEXT NOT NULL CHECK(owner IN ('rui','provider')),
    \\ description_content_id INTEGER NOT NULL REFERENCES content(content_id),
    \\ input_schema_content_id INTEGER NOT NULL REFERENCES content(content_id),
    \\ UNIQUE(name,owner,description_content_id,input_schema_content_id)
    \\) STRICT
    ,
    \\CREATE TABLE tool_set(
    \\ tool_set_id INTEGER PRIMARY KEY NOT NULL CHECK(tool_set_id>0),
    \\ digest BLOB NOT NULL UNIQUE CHECK(length(digest)=32),
    \\ member_count INTEGER NOT NULL CHECK(member_count BETWEEN 0 AND 128),
    \\ names TEXT NOT NULL CHECK(length(CAST(names AS BLOB))<=4223 AND (names NOT GLOB '*[^A-Za-z0-9_ -]*' AND length(names)=length(CAST(names AS BLOB))))
    \\) STRICT
    ,
    \\CREATE TABLE tool_set_member(
    \\ tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id),
    \\ ordinal INTEGER NOT NULL CHECK(ordinal>=0),
    \\ tool_record_id INTEGER NOT NULL REFERENCES tool_record(tool_record_id),
    \\ PRIMARY KEY(tool_set_id,ordinal)
    \\) STRICT, WITHOUT ROWID
    ,
    "INSERT INTO content(content_id,digest,byte_length,private,payload) SELECT (SELECT coalesce(max(content_id),0)+1 FROM content),X'4f66196d0cd7f65cfedb1f6351c95fa0f2d11d29418a366b3121e62bdac14845',633,0,X'52756e2042617368206f6e20746865206c6f63616c206d616368696e652e20456163682063616c6c2073746172747320696e207468652053657373696f6e20576f726b73706163653b2072656c6174697665207061746873207265736f6c76652074686572652c207768696c65206162736f6c7574652070617468732063616e20616363657373206f7574736964652069742e2053746172742066696c6573797374656d206578706c6f726174696f6e20746865726520616e642062726f6164656e207365617263686573206f6e6c79206173206e65656465642e205075742074657874207061796c6f61647320696e20737464696e2c206e6576657220696e7369646520636d642e204261736820686173206e6f207465726d696e616c3a206e6f206f6e652063616e207479706520696e746f20612072756e6e696e672063616c6c2c20736f2070617373776f72642070726f6d70747320287375646f2c20696e636c7564696e6720696e7374616c6c65727320746861742072756e2069742920616e6420696e7465726163746976652070726f6772616d73206661696c2e205768656e20666c616773206f7220737464696e2063616e6e6f7420616e7377657220612070726f6d70742c20676976652074686520636f6d6d616e6420746f20746865207573657220746f2072756e20696e207468656972206f776e207465726d696e616c3a206265666f72652072756e6e696e67206974207768656e20796f752063616e2074656c6c2069742077696c6c2070726f6d70742c206f7468657277697365206166746572206974732066697273742073756368206661696c7572652e20446f206e6f7420726574727920697420686572652e' WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (1,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (1,3))) AND NOT EXISTS(SELECT 1 FROM content WHERE digest=X'4f66196d0cd7f65cfedb1f6351c95fa0f2d11d29418a366b3121e62bdac14845' AND byte_length=633 AND private=0)",
    "INSERT INTO content(content_id,digest,byte_length,private,payload) SELECT (SELECT coalesce(max(content_id),0)+1 FROM content),X'7a478a1b836850fe5d32bc5580440b303691e7efee40b5c5f4b65fd2877fe1b9',1147,0,X'7b2274797065223a226f626a656374222c2270726f70657274696573223a7b22636d64223a7b2274797065223a22737472696e67227d2c22737464696e223a7b2274797065223a22737472696e67222c226465736372697074696f6e223a224f7074696f6e616c2e204c69746572616c205554462d3820746578742c206174206d6f737420313232383830206465636f6465642062797465732c20726561642065786163746c79207468656e20454f462e204f6d69747465642c20737464696e206973202f6465762f6e756c6c2e227d2c226465736372697074696f6e223a7b2274797065223a22737472696e67222c226465736372697074696f6e223a22412073686f72742068756d616e2d666163696e67206163746976697479206c6162656c3a20626173652076657262202b20636f6e637265746520746172676574202b2075736566756c2073636f70652c20696e2073656e74656e636520636173652077697468206e6f20747261696c696e672070756e6374756174696f6e2e2044657363726962652074686520696e74656e64656420776f726b2c206e6f7420697473207374617475732c2073756363657373206f72207361666574792e2052657175697265642c206e6f6e626c616e6b2c2073696e676c652d6c696e652076616c6964205554462d382c206174206d6f737420313030206465636f646564205554462d382062797465732e2041696d20666f72203430e28093363020636861726163746572733b20757365206d6f7265206f6e6c7920666f722075736566756c2073636f70652e204578616d706c653a2052756e207061727365722072656772657373696f6e207465737473227d2c2274696d656f75745f6d73223a7b2274797065223a22696e7465676572222c226465736372697074696f6e223a224f7074696f6e616c2e204f6d697420697420666f722074686520486f73742064656661756c7420756e6c6573732074686520776f726b206e65656473206120646966666572656e74206275646765742e204120706f73697469766520696e7465676572207265706c616365732069742077697468206120746f74616c20656c617073656420657865637574696f6e2062756467657420696e206d696c6c697365636f6e64732066726f6d2070726f636573732073746172743b206f757470757420646f6573206e6f742072657365742069742e20416c6c6f7720656e6f7567682074696d6520666f722073656172636865732c206275696c647320616e642074657374732e2045787069727920656e6473207468652063616c6c207468726f7567682070726f636573732d67726f7570207465726d696e6174696f6e2c206e6f742061206261636b67726f756e642068616e646c653b207061727469616c2065666665637473206d61792072656d61696e2e222c226d696e696d756d223a312c226d6178696d756d223a393232333337323033363835343737353830377d7d2c227265717569726564223a5b22636d64222c226465736372697074696f6e225d2c226164646974696f6e616c50726f70657274696573223a66616c73657d' WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (1,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (1,3))) AND NOT EXISTS(SELECT 1 FROM content WHERE digest=X'7a478a1b836850fe5d32bc5580440b303691e7efee40b5c5f4b65fd2877fe1b9' AND byte_length=1147 AND private=0)",
    "INSERT INTO content(content_id,digest,byte_length,private,payload) SELECT (SELECT coalesce(max(content_id),0)+1 FROM content),X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528',0,0,X'' WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (2,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (2,3))) AND NOT EXISTS(SELECT 1 FROM content WHERE digest=X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528' AND byte_length=0 AND private=0)",
    "INSERT INTO tool_record(tool_record_id,name,owner,description_content_id,input_schema_content_id) SELECT 1,'bash','rui',(SELECT content_id FROM content WHERE digest=X'4f66196d0cd7f65cfedb1f6351c95fa0f2d11d29418a366b3121e62bdac14845' AND byte_length=633 AND private=0),(SELECT content_id FROM content WHERE digest=X'7a478a1b836850fe5d32bc5580440b303691e7efee40b5c5f4b65fd2877fe1b9' AND byte_length=1147 AND private=0) WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (1,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (1,3)))",
    "INSERT INTO tool_record(tool_record_id,name,owner,description_content_id,input_schema_content_id) SELECT 2,'web_search','provider',(SELECT content_id FROM content WHERE digest=X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528' AND byte_length=0 AND private=0),(SELECT content_id FROM content WHERE digest=X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528' AND byte_length=0 AND private=0) WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (2,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (2,3)))",
    "INSERT INTO tool_set(tool_set_id,digest,member_count,names) SELECT used.tools_mask+1,CASE used.tools_mask WHEN 0 THEN X'fe748044351540765e2284e8b22eee2921470a1314d382303cdc7075a2ae4848' WHEN 1 THEN X'0925160f7c7b0c47c90f761fe1302c8ee88e8e7393a05916ed42a1ee2993b6d2' WHEN 2 THEN X'd9cfc45bb675c92d875c57d0206db60df3cdf46d271687b6a6d34ceecde1e968' WHEN 3 THEN X'1e1125a25d2df26dec099adfa35d375282a5318a4f72178d5b641d219f76f9da' END,CASE used.tools_mask WHEN 0 THEN 0 WHEN 1 THEN 1 WHEN 2 THEN 1 WHEN 3 THEN 2 END,CASE used.tools_mask WHEN 0 THEN '' WHEN 1 THEN 'bash' WHEN 2 THEN 'web_search' WHEN 3 THEN 'bash web_search' END FROM (SELECT tools_mask FROM session UNION SELECT tools_mask FROM session_revision) used",
    "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT tool_set_id,0,CASE WHEN tool_set_id=3 THEN 2 ELSE 1 END FROM tool_set WHERE tool_set_id>1",
    "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT tool_set_id,1,2 FROM tool_set WHERE tool_set_id=4",
    "ALTER TABLE session RENAME TO session_old",
    \\CREATE TABLE session(
    \\ session_ref TEXT PRIMARY KEY NOT NULL CHECK(length(CAST(session_ref AS BLOB))=6 AND (session_ref NOT GLOB '*[^0123456789abcdefghjkmnpqrstvwxyz]*' AND length(session_ref)=length(CAST(session_ref AS BLOB)))),
    \\ workspace TEXT NOT NULL CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096),
    \\ provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND (provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))),
    \\ codec TEXT NOT NULL CHECK(length(CAST(codec AS BLOB)) BETWEEN 3 AND 40),
    \\ codec_options BLOB CHECK(codec_options IS NULL OR length(codec_options) BETWEEN 1 AND 512),
    \\ prefix_seal BLOB CHECK(prefix_seal IS NULL OR length(prefix_seal)=56),
    \\ model TEXT NOT NULL CHECK(length(CAST(model AS BLOB)) BETWEEN 1 AND 256),
    \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
    \\ tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id) CHECK(tool_set_id>0),
    \\ permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
    \\ output_schema_content_id INTEGER REFERENCES content(content_id),
    \\ revision INTEGER NOT NULL CHECK(revision>0),
    \\ compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
    \\ output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),
    \\ reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),
    \\ label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),
    \\ created_at INTEGER NOT NULL CHECK(created_at>0),
    \\ next_position INTEGER NOT NULL CHECK(next_position>0),
    \\ created_seq INTEGER NOT NULL UNIQUE CHECK(created_seq>0),
    \\ workspace_digest BLOB NOT NULL CHECK(length(workspace_digest)=32),
    \\ workspace_key INTEGER NOT NULL,
    \\ CHECK(workspace_key>0 AND workspace_key<=created_seq)
    \\) STRICT
    ,
    "INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key) SELECT session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tools_mask+1,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key FROM session_old",
    "DROP TABLE session_old",
    "CREATE INDEX session_workspace_list ON session(workspace_digest,created_seq)",
    "ALTER TABLE session_revision RENAME TO session_revision_old",
    \\CREATE TABLE session_revision(
    \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
    \\ revision INTEGER NOT NULL CHECK(revision>0),
    \\ command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key),
    \\ workspace TEXT NOT NULL,
    \\ provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND (provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))),
    \\ model TEXT NOT NULL,
    \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
    \\ instructions_updated INTEGER NOT NULL CHECK(instructions_updated IN (0,1)),
    \\ tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id) CHECK(tool_set_id>0),
    \\ permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
    \\ output_schema_content_id INTEGER REFERENCES content(content_id),
    \\ compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
    \\ output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),
    \\ reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),
    \\ label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),
    \\ PRIMARY KEY(session_ref,revision)
    \\) STRICT, WITHOUT ROWID
    ,
    "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label) SELECT session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tools_mask+1,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label FROM session_revision_old",
    "DROP TABLE session_revision_old",
    "CREATE INDEX model_operation_admission ON model_operation(session_ref,admission_position)",
};

pub const mysql = [_][:0]const u8{
    \\CREATE TABLE tool_record(
    \\ tool_record_id BIGINT NOT NULL,
    \\ name VARCHAR(64) NOT NULL,
    \\ owner VARCHAR(8) NOT NULL,
    \\ description_content_id BIGINT NOT NULL,
    \\ input_schema_content_id BIGINT NOT NULL,
    \\ PRIMARY KEY(tool_record_id),
    \\ UNIQUE(name,owner,description_content_id,input_schema_content_id),
    \\ FOREIGN KEY(description_content_id) REFERENCES content(content_id),
    \\ FOREIGN KEY(input_schema_content_id) REFERENCES content(content_id),
    \\ CHECK(tool_record_id>0),
    \\ CHECK(OCTET_LENGTH(name) BETWEEN 1 AND 64 AND (NOT REGEXP_LIKE(name,'[^A-Za-z0-9_-]','c'))),
    \\ CHECK(owner IN ('rui','provider'))
    \\) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin
    ,
    \\CREATE TABLE tool_set(
    \\ tool_set_id BIGINT NOT NULL,
    \\ digest VARBINARY(32) NOT NULL,
    \\ member_count BIGINT NOT NULL,
    \\ names TEXT NOT NULL,
    \\ PRIMARY KEY(tool_set_id),
    \\ UNIQUE(digest),
    \\ CHECK(tool_set_id>0),
    \\ CHECK(length(digest)=32),
    \\ CHECK(member_count BETWEEN 0 AND 128),
    \\ CHECK(OCTET_LENGTH(names)<=4223 AND (NOT REGEXP_LIKE(names,'[^A-Za-z0-9_ -]','c')))
    \\) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin
    ,
    \\CREATE TABLE tool_set_member(
    \\ tool_set_id BIGINT NOT NULL,
    \\ ordinal BIGINT NOT NULL,
    \\ tool_record_id BIGINT NOT NULL,
    \\ PRIMARY KEY(tool_set_id,ordinal),
    \\ FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id),
    \\ FOREIGN KEY(tool_record_id) REFERENCES tool_record(tool_record_id),
    \\ CHECK(ordinal>=0)
    \\) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin
    ,
    "INSERT INTO content(content_id,digest,byte_length,private,payload) SELECT (SELECT coalesce(max(content_id),0)+1 FROM content),X'4f66196d0cd7f65cfedb1f6351c95fa0f2d11d29418a366b3121e62bdac14845',633,0,X'52756e2042617368206f6e20746865206c6f63616c206d616368696e652e20456163682063616c6c2073746172747320696e207468652053657373696f6e20576f726b73706163653b2072656c6174697665207061746873207265736f6c76652074686572652c207768696c65206162736f6c7574652070617468732063616e20616363657373206f7574736964652069742e2053746172742066696c6573797374656d206578706c6f726174696f6e20746865726520616e642062726f6164656e207365617263686573206f6e6c79206173206e65656465642e205075742074657874207061796c6f61647320696e20737464696e2c206e6576657220696e7369646520636d642e204261736820686173206e6f207465726d696e616c3a206e6f206f6e652063616e207479706520696e746f20612072756e6e696e672063616c6c2c20736f2070617373776f72642070726f6d70747320287375646f2c20696e636c7564696e6720696e7374616c6c65727320746861742072756e2069742920616e6420696e7465726163746976652070726f6772616d73206661696c2e205768656e20666c616773206f7220737464696e2063616e6e6f7420616e7377657220612070726f6d70742c20676976652074686520636f6d6d616e6420746f20746865207573657220746f2072756e20696e207468656972206f776e207465726d696e616c3a206265666f72652072756e6e696e67206974207768656e20796f752063616e2074656c6c2069742077696c6c2070726f6d70742c206f7468657277697365206166746572206974732066697273742073756368206661696c7572652e20446f206e6f7420726574727920697420686572652e' FROM DUAL WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (1,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (1,3))) AND NOT EXISTS(SELECT 1 FROM content WHERE digest=X'4f66196d0cd7f65cfedb1f6351c95fa0f2d11d29418a366b3121e62bdac14845' AND byte_length=633 AND private=0)",
    "INSERT INTO content(content_id,digest,byte_length,private,payload) SELECT (SELECT coalesce(max(content_id),0)+1 FROM content),X'7a478a1b836850fe5d32bc5580440b303691e7efee40b5c5f4b65fd2877fe1b9',1147,0,X'7b2274797065223a226f626a656374222c2270726f70657274696573223a7b22636d64223a7b2274797065223a22737472696e67227d2c22737464696e223a7b2274797065223a22737472696e67222c226465736372697074696f6e223a224f7074696f6e616c2e204c69746572616c205554462d3820746578742c206174206d6f737420313232383830206465636f6465642062797465732c20726561642065786163746c79207468656e20454f462e204f6d69747465642c20737464696e206973202f6465762f6e756c6c2e227d2c226465736372697074696f6e223a7b2274797065223a22737472696e67222c226465736372697074696f6e223a22412073686f72742068756d616e2d666163696e67206163746976697479206c6162656c3a20626173652076657262202b20636f6e637265746520746172676574202b2075736566756c2073636f70652c20696e2073656e74656e636520636173652077697468206e6f20747261696c696e672070756e6374756174696f6e2e2044657363726962652074686520696e74656e64656420776f726b2c206e6f7420697473207374617475732c2073756363657373206f72207361666574792e2052657175697265642c206e6f6e626c616e6b2c2073696e676c652d6c696e652076616c6964205554462d382c206174206d6f737420313030206465636f646564205554462d382062797465732e2041696d20666f72203430e28093363020636861726163746572733b20757365206d6f7265206f6e6c7920666f722075736566756c2073636f70652e204578616d706c653a2052756e207061727365722072656772657373696f6e207465737473227d2c2274696d656f75745f6d73223a7b2274797065223a22696e7465676572222c226465736372697074696f6e223a224f7074696f6e616c2e204f6d697420697420666f722074686520486f73742064656661756c7420756e6c6573732074686520776f726b206e65656473206120646966666572656e74206275646765742e204120706f73697469766520696e7465676572207265706c616365732069742077697468206120746f74616c20656c617073656420657865637574696f6e2062756467657420696e206d696c6c697365636f6e64732066726f6d2070726f636573732073746172743b206f757470757420646f6573206e6f742072657365742069742e20416c6c6f7720656e6f7567682074696d6520666f722073656172636865732c206275696c647320616e642074657374732e2045787069727920656e6473207468652063616c6c207468726f7567682070726f636573732d67726f7570207465726d696e6174696f6e2c206e6f742061206261636b67726f756e642068616e646c653b207061727469616c2065666665637473206d61792072656d61696e2e222c226d696e696d756d223a312c226d6178696d756d223a393232333337323033363835343737353830377d7d2c227265717569726564223a5b22636d64222c226465736372697074696f6e225d2c226164646974696f6e616c50726f70657274696573223a66616c73657d' FROM DUAL WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (1,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (1,3))) AND NOT EXISTS(SELECT 1 FROM content WHERE digest=X'7a478a1b836850fe5d32bc5580440b303691e7efee40b5c5f4b65fd2877fe1b9' AND byte_length=1147 AND private=0)",
    "INSERT INTO content(content_id,digest,byte_length,private,payload) SELECT (SELECT coalesce(max(content_id),0)+1 FROM content),X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528',0,0,X'' FROM DUAL WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (2,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (2,3))) AND NOT EXISTS(SELECT 1 FROM content WHERE digest=X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528' AND byte_length=0 AND private=0)",
    "INSERT INTO tool_record(tool_record_id,name,owner,description_content_id,input_schema_content_id) SELECT 1,'bash','rui',(SELECT content_id FROM content WHERE digest=X'4f66196d0cd7f65cfedb1f6351c95fa0f2d11d29418a366b3121e62bdac14845' AND byte_length=633 AND private=0),(SELECT content_id FROM content WHERE digest=X'7a478a1b836850fe5d32bc5580440b303691e7efee40b5c5f4b65fd2877fe1b9' AND byte_length=1147 AND private=0) FROM DUAL WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (1,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (1,3)))",
    "INSERT INTO tool_record(tool_record_id,name,owner,description_content_id,input_schema_content_id) SELECT 2,'web_search','provider',(SELECT content_id FROM content WHERE digest=X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528' AND byte_length=0 AND private=0),(SELECT content_id FROM content WHERE digest=X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528' AND byte_length=0 AND private=0) FROM DUAL WHERE (EXISTS(SELECT 1 FROM session WHERE tools_mask IN (2,3)) OR EXISTS(SELECT 1 FROM session_revision WHERE tools_mask IN (2,3)))",
    "INSERT INTO tool_set(tool_set_id,digest,member_count,names) SELECT used.tools_mask+1,CASE used.tools_mask WHEN 0 THEN X'fe748044351540765e2284e8b22eee2921470a1314d382303cdc7075a2ae4848' WHEN 1 THEN X'0925160f7c7b0c47c90f761fe1302c8ee88e8e7393a05916ed42a1ee2993b6d2' WHEN 2 THEN X'd9cfc45bb675c92d875c57d0206db60df3cdf46d271687b6a6d34ceecde1e968' WHEN 3 THEN X'1e1125a25d2df26dec099adfa35d375282a5318a4f72178d5b641d219f76f9da' END,CASE used.tools_mask WHEN 0 THEN 0 WHEN 1 THEN 1 WHEN 2 THEN 1 WHEN 3 THEN 2 END,CASE used.tools_mask WHEN 0 THEN '' WHEN 1 THEN 'bash' WHEN 2 THEN 'web_search' WHEN 3 THEN 'bash web_search' END FROM (SELECT tools_mask FROM session UNION SELECT tools_mask FROM session_revision) used",
    "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT tool_set_id,0,CASE WHEN tool_set_id=3 THEN 2 ELSE 1 END FROM tool_set WHERE tool_set_id>1",
    "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT tool_set_id,1,2 FROM tool_set WHERE tool_set_id=4",
    "ALTER TABLE session ADD COLUMN tool_set_id BIGINT AFTER instructions_content_id",
    "UPDATE session SET tool_set_id=tools_mask+1",
    "ALTER TABLE session MODIFY tool_set_id BIGINT NOT NULL, ADD CHECK(tool_set_id>0), ADD FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id), DROP COLUMN tools_mask",
    "ALTER TABLE session_revision ADD COLUMN tool_set_id BIGINT AFTER instructions_content_id",
    "UPDATE session_revision SET tool_set_id=tools_mask+1",
    "ALTER TABLE session_revision MODIFY tool_set_id BIGINT NOT NULL, ADD CHECK(tool_set_id>0), ADD FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id), DROP COLUMN tools_mask",
    \\CREATE INDEX model_operation_admission ON model_operation(session_ref,admission_position)
    \\failed command: RUI_TEST_EXACT_INACTIVITY=0 ./.zig-cache/o/ee8606cfc23c29c3daec7cd527cd94a4/test --cache-dir=./.zig-cache --seed=0x835dc9cd --listen=-
    \\
    ,
};
