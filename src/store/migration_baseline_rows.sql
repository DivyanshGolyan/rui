INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES
(1,X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528',0,0,X''),
(2,X'295e577a7a0c2608c470cb327496d5b7f60b8f53b5ebf48f6878d2cdd614e333',5,0,X'696e707574'),
(3,X'11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528',0,1,X''),
(4,X'0e9950c0be018cee2261d1dfd87cfbba350d1428cda8cba2df11b077531f7b40',8,1,X'226964223a226d22'),
(5,X'ae8a082549d1d33e5ebd00dfb22c08dd7a9cdd2bf87eb79863de71c7bde37b53',11,0,X'68656c6c6f0a776f726c64'),
(6,X'b3d406f1800f595b26a2be8c410f6205a4578cec458ca5219d7b4343b4c3d8d4',7,0,X'70726f706f7365'),
(7,X'f4b634bb5e77777802860e06b1a22a499b63bd40ca06400cd6346db9eb5a77bd',13,1,X'226964223a226974656d2d3122'),
(8,X'7a43f70a610efb179b6c8581bb3bf49506e9472f16baac785e452491f5e0bb64',13,1,X'226964223a226974656d2d3222'),
(9,X'a0fbca0ae84c22252231e4bffa4714809c6d0949720b266767b8fce2aae50557',4,0,X'62617368'),
(10,X'5e2ab58aab1f361a7463d83515ae4f2519f54468f5dbc37e1a30c35f7b6defed',6,0,X'63616c6c0a41'),
(11,X'f1a4d9bc3bf8c59e61a8111bc926dbd19ecd2adb95e7879a75e598dc0876b115',65,0,X'7b226465736372697074696f6e223a2252756e20666972737420636f6d6d616e64222c22636d64223a226f6e65222c2274696d656f75745f6d73223a6e756c6c7d'),
(12,X'2424a1124da95105ad0cae02f8974290bcdfa6b8f722ab0a9010a03d85dc70aa',6,0,X'63616c6c2d42'),
(13,X'218db1eed2b15d82d37c2be4440ff39e46365886bd914326b0bf6fceee17f4d1',66,0,X'7b226465736372697074696f6e223a2252756e207365636f6e6420636f6d6d616e64222c22636d64223a2274776f222c2274696d656f75745f6d73223a6e756c6c7d');
INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key) VALUES
('d8mv7p','/home/user/rui-pr6d','codex','openai-responses/1',NULL,NULL,'model-a',1,3,1,NULL,1,NULL,NULL,NULL,NULL,1793781720,6,1,X'4f734373106b18b4300a06683393f27fe72fcb98f82b72cb0a3b98950e714433',1),
('brhkcj','/home/user/rui-pr6d','codex','openai-responses/1',NULL,NULL,'model-a',1,1,0,NULL,1,NULL,NULL,NULL,NULL,1793781720,6,2,X'4f734373106b18b4300a06683393f27fe72fcb98f82b72cb0a3b98950e714433',1),
('rhvzwc','/home/user/rui-pr6d','codex','openai-responses/1',NULL,NULL,'model-a',1,3,1,NULL,1,NULL,NULL,NULL,NULL,1793781720,2,3,X'4f734373106b18b4300a06683393f27fe72fcb98f82b72cb0a3b98950e714433',1);
INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES
('fixture-answer-config',1,'d8mv7p',X'da30d53055d72b570beed083a96a9fbff59605a11f6606d8c06009c43a705489',NULL,NULL,1,'',1,1,1),
('fixture-answer-key',2,'d8mv7p',X'f1c556d56340cf43f947a5c7efa143b121b78165d59292dc801d9331b8e7206a',2,NULL,1,'',0,0,2),
('fixture-ask-config',1,'brhkcj',X'cec44ce76850ac8d1faa17c7e708d732723b13fde5c482502faa9fd93f8581ac',NULL,NULL,1,'',1,1,3),
('fixture-ask-message',2,'brhkcj',X'95937f206811b07f694d1973bece7e5a13bddb2f45fc92bfa330b713a8043aa3',6,NULL,1,'',0,0,4),
('fixture-allow',5,'brhkcj',X'7cf72581b6f2592ba788fe2b2306da74e37d8ac8f2b115d67e5143d20eae18e9',NULL,NULL,1,'',0,0,5),
('fixture-stop-config',1,'rhvzwc',X'da30d53055d72b570beed083a96a9fbff59605a11f6606d8c06009c43a705489',NULL,NULL,1,'',1,1,6),
('fixture-stop',3,'rhvzwc',X'd3a4ebf602e078b77bf4e4ccc2b6ab98d0c70d556138a870ca01f9a655dca65f',NULL,NULL,1,'',0,0,7),
('fixture-interrupt',4,'d8mv7p',X'f36b025999732c650e4e9c3ff7505e214dfcfd0c0e8cf3ef162d75d9f32d6129',NULL,NULL,0,'operation_resolved',0,0,8),
('fixture-rejected',2,'k7m2qx',X'cc0e17dc4472ec1578e9a655c97150feecee8729a14928bc7382c9a61005e1b9',NULL,NULL,0,'unknown_session',0,0,9);
INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tools_mask,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label) VALUES
('brhkcj',1,'fixture-ask-config','/home/user/rui-pr6d','codex','model-a',1,1,1,0,NULL,NULL,NULL,NULL,NULL),
('d8mv7p',1,'fixture-answer-config','/home/user/rui-pr6d','codex','model-a',1,1,3,1,NULL,NULL,NULL,NULL,NULL),
('rhvzwc',1,'fixture-stop-config','/home/user/rui-pr6d','codex','model-a',1,1,3,1,NULL,NULL,NULL,NULL,NULL);
INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at,sender_session_ref,sender_position) VALUES
(1,'d8mv7p','fixture-answer-key',2,1,1,1793781720,NULL,NULL),
(2,'brhkcj','fixture-ask-message',6,1,2,1793781720,NULL,NULL);
INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id,outcome_position,outcome_at,continuation_operation_id) VALUES
(1,'d8mv7p',1,1,1,'completed',5,5,1793781720,NULL),
(2,'brhkcj',2,2,2,NULL,NULL,NULL,NULL,NULL);
INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at) VALUES
('fixture-stop','rhvzwc',NULL,1,0,1793781720);
INSERT INTO model_interruption_command(command_key,session_ref,turn_id,operation_id) VALUES
('fixture-interrupt','d8mv7p','1','1');
INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_content_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at) VALUES
(1,1,'d8mv7p',1,1,3,0,115200,0,NULL,1,1,0,NULL,NULL,'answer',5,NULL,X'01000000000000',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1793781720),
(2,2,'brhkcj',1,2,3,0,115200,0,NULL,2,1,0,NULL,NULL,'tool_proposals',NULL,NULL,X'01000000000000',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1793781720);
INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,source_item_ordinal,content_id,recorded_at) VALUES
('brhkcj',1,2,1,2,2,NULL,NULL,NULL,6,1793781720),
('d8mv7p',1,2,1,1,1,NULL,NULL,NULL,2,1793781720),
('d8mv7p',2,4,3,1,NULL,NULL,1,0,5,1793781720);
INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) VALUES
(1,0,'d8mv7p',4,2,5,1,X'39dbe3cba52908fdb3610df812d007a7fc134eea8803b34a97e9aa229d815fae',0,0,4,1,NULL,0),
(2,0,'brhkcj',4,3,NULL,1,X'0fdadc71d7984bbccd4a62ba37f7193aa30afb66119760165a70058d4aea629d',0,0,7,0,NULL,0),
(2,1,'brhkcj',5,3,NULL,1,X'f9102a092552727d93c8e12e9a1a876ff1935a88476f27d45f0af576e99c4ce5',0,0,8,0,NULL,0);
INSERT INTO model_output_part(operation_id,item_ordinal,part_ordinal,part_array,part_kind,text_length,text_content_id,extras_content_id) VALUES
(1,0,0,1,1,11,NULL,3);
INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,description,field_metadata,rejection_code,rejection_content_id,acceptance_position,action_kind) VALUES
(2,'brhkcj',0,0,9,10,11,'Run first command',X'0400000000000000a0fbca0ae84c22252231e4bffa4714809c6d0949720b266767b8fce2aae5055706000000000000005e2ab58aab1f361a7463d83515ae4f2519f54468f5dbc37e1a30c35f7b6defed4100000000000000f1a4d9bc3bf8c59e61a8111bc926dbd19ecd2adb95e7879a75e598dc0876b115',NULL,NULL,NULL,1),
(2,'brhkcj',1,1,9,12,13,'Run second command',X'0400000000000000a0fbca0ae84c22252231e4bffa4714809c6d0949720b266767b8fce2aae5055706000000000000002424a1124da95105ad0cae02f8974290bcdfa6b8f722ab0a9010a03d85dc70aa4200000000000000218db1eed2b15d82d37c2be4440ff39e46365886bd914326b0bf6fceee17f4d1',NULL,NULL,NULL,1);
INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,attempt_ordinal,bash_timeout_override_ms,bash_timeout_ms,sender_handle,resolution_code,resolution_content_id,acceptance_position,attempt_at,decided_at,resolved_at) VALUES
(1,2,0,'brhkcj',1,1,1,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1793781720,NULL),
(2,2,1,'brhkcj',1,1,0,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL);
INSERT INTO permission_decision_command(command_key,action_id,decision) VALUES
('fixture-allow','1','allow_once');
