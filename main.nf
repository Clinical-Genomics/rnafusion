#!/usr/bin/env nextflow
/*
================================================================================
                                nf-core/rnafusion
================================================================================
nf-core/rnafusion:
 RNA-seq analysis pipeline for detection gene-fusions
--------------------------------------------------------------------------------
 @Homepage
 https://nf-co.re/rnafusion
--------------------------------------------------------------------------------
 @Documentation
 https://nf-co.re/rnafusion/docs
--------------------------------------------------------------------------------
 @Repository
 https://github.com/nf-core/rnafusion
--------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/rnafusion --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    Tool flags:
      --arriba                      Run Arriba
      --arriba_opt                  Specify extra parameters for Arriba
      --star_fusion                 Run STAR-Fusion
      --star_fusion_opt             Specify extra parameters for STAR-Fusion
      --fusioncatcher               Run FusionCatcher
      --fusioncatcher_opt           Specify extra parameters for FusionCatcher
      --ericscript                  Run Ericscript
      --pizzly                      Run Pizzly
      --squid                       Run Squid
      --databases                   Database path for fusion-report
      --fusion_report_opt           Specify extra parameters for fusion-report

    Visualization flags:
      --arriba_vis                  Generate a PDF visualization per detected fusion
      --fusion_inspector            Run Fusion-Inspector

    References                      If not specified in the configuration file or you wish to overwrite any of the references.
      --fasta                       Path to Fasta reference
      --gtf                         Path to GTF annotation
      --transcript                  Path to transcript
      --star_index                  Path to STAR-Index reference
      --star_fusion_ref             Path to STAR-Fusion reference
      --fusioncatcher_ref           Path to Fusioncatcher reference
      --ericscript_ref              Path to Ericscript reference
      --arriba_ref                  Path to Arriba reference

    Options:
      --read_length                 Length of the reads. Default: 100
      --singleEnd                   Specifies that the input is single end reads

    Other Options:
      --debug                       Flag to run only specific fusion tool/s and not the whole pipeline. Only works on tool flags.
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
================================================================================
                         SET UP CONFIGURATION VARIABLES
================================================================================
*/

// Show help message
if (params.help) exit 0, helpMessage()

running_tools = []
visualization_tools = []
reference = [
    arriba: false,
    arriba_vis: false,
    ericscript: false,
    fusion_inspector: false,
    fusioncatcher: false,
    star_fusion: false
]

ch_fasta = Channel.value(file(params.fasta)).ifEmpty{exit 1, "Fasta file not found: ${params.fasta}"}
ch_gtf = Channel.value(file(params.gtf)).ifEmpty{exit 1, "GTF annotation file not found: ${params.gtf}"}
ch_transcript = Channel.value(file(params.transcript)).ifEmpty{exit 1, "Transcript file not found: ${params.transcript}"}

if (!params.star_index && (!params.fasta && !params.gtf)) exit 1, "Either specify STAR-INDEX or Fasta and GTF!"

if (!params.databases) exit 1, "Database path for fusion-report has to be specified!"

if (params.arriba) {
    running_tools.add("Arriba")
    reference.arriba = Channel.value(file(params.arriba_ref)).ifEmpty{exit 1, "Arriba reference directory not found!"}
}

if (params.arriba_vis) {
    visualization_tools.add("Arriba")
    reference.arriba_vis = Channel.value(file(params.arriba_ref)).ifEmpty{exit 1, "Arriba visualization reference directory not found!"}
}

if (params.ericscript) {
    running_tools.add("EricScript")
    reference.ericscript = Channel.value(file(params.ericscript_ref)).ifEmpty{exit 1, "EricsSript reference not found!"}
}

if (params.fusioncatcher) {
    running_tools.add("Fusioncatcher")
    reference.fusioncatcher = Channel.value(file(params.fusioncatcher_ref)).ifEmpty{exit 1, "Fusioncatcher data directory not found!"}
}

if (params.fusion_inspector) {
    visualization_tools.add("Fusion-Inspector")
    reference.fusion_inspector = Channel.value(file(params.star_fusion_ref)).ifEmpty{exit 1, "Fusion-Inspector reference not found" }
}

if (params.pizzly) running_tools.add("Pizzly")

if (params.star_fusion) {
    running_tools.add("STAR-Fusion")
    reference.star_fusion = Channel.value(file(params.star_fusion_ref)).ifEmpty{exit 1, "Star-Fusion reference directory not found!"}
}

if (params.squid) running_tools.add("Squid")

// Has the run name been specified by the user?
// This has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) custom_runName = workflow.runName

if (workflow.profile == 'awsbatch') {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

/*
 * Create a channel for input read files
 */
if(params.readPaths) {
    if(params.singleEnd) {
        Channel.from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0])]] }
            .ifEmpty{exit 1, "params.readPaths was empty - no input files supplied" }
            .into{read_files_arriba; read_files_ericscript; read_files_fastqc; read_files_fusion_inspector; read_files_fusioncatcher; read_files_multiqc; read_files_pizzly; read_files_squid; read_files_star_fusion; read_files_summary}
    } else {
        Channel.from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0]), file(row[1][1])]] }
            .ifEmpty{exit 1, "params.readPaths was empty - no input files supplied" }
            .into{read_files_arriba; read_files_ericscript; read_files_fastqc; read_files_fusion_inspector; read_files_fusioncatcher; read_files_multiqc; read_files_pizzly; read_files_squid; read_files_star_fusion; read_files_summary}
    }
} else {
    Channel.fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
        .ifEmpty{exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --singleEnd on the command line." }
        .into{read_files_arriba; read_files_ericscript; read_files_fastqc; read_files_fusion_inspector; read_files_fusioncatcher; read_files_multiqc; read_files_pizzly; read_files_squid; read_files_star_fusion; read_files_summary}
}

/*
================================================================================
                                PRINTING SUMMARY
================================================================================
*/

// Header log info
log.info nfcoreHeader()
def summary = [:]
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']     = custom_runName ?: workflow.runName
summary['Reads']        = params.reads
summary['Fasta Ref']    = params.fasta
summary['GTF Ref']      = params.gtf
summary['STAR Index']   = params.star_index ? params.star_index : 'Not specified, building'
summary['Fusion tools']        = running_tools.size() == 0 ? 'None' : running_tools.join(", ")
summary['Visualization tools'] = visualization_tools.size() == 0 ? 'None': visualization_tools.join(", ")
summary['Data Type']        = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']   = params.outdir
summary['Launch dir']   = workflow.launchDir
summary['Working dir']  = workflow.workDir
summary['Script dir']   = workflow.projectDir
summary['User']         = workflow.userName
if(workflow.profile == 'awsbatch') {
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-rnafusion-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/rnafusion Workflow Summary'
    section_href: 'https://github.com/nf-core/rnafusion'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
================================================================================
                                  PREPROCESSING
================================================================================
*/

/*
 * Build STAR index
 */

process build_star_index {
    tag "$fasta"
    publishDir "${params.outdir}/star-index", mode: 'copy'

    input:
    file(fasta) from ch_fasta
    file(gtf) from ch_gtf

    output:
    file("star") into star_index

    when: !(params.star_index)

    script:
    def avail_mem = task.memory ? "--limitGenomeGenerateRAM ${task.memory.toBytes() - 100000000}" : ''
    """
    mkdir star
    STAR \\
        --runMode genomeGenerate \\
        --runThreadN ${task.cpus} \\
        --sjdbGTFfile ${gtf} \\
        --sjdbOverhang ${params.read_length - 1} \\
        --genomeDir star/ \\
        --genomeFastaFiles ${fasta} \\
        $avail_mem
    """
}

ch_star_index = params.star_index ? Channel.value(file(params.star_index)).ifEmpty{exit 1, "STAR index not found: ${params.star_index}" } : star_index

ch_star_index = ch_star_index.dump(tag:'ch_star_index')

/*
================================================================================
                                 FUSION PIPELINE
================================================================================
*/

/*
 * Arriba
 */
process arriba {
    tag {sample}

    publishDir "${params.outdir}/tools/Arriba/${sample}", mode: 'copy'

    when:
    params.arriba && (!params.singleEnd || params.debug)

    input:
    set val(sample), file(reads) from read_files_arriba
    file(reference) from reference.arriba
    file(star_index) from ch_star_index
    file(fasta) from ch_fasta
    file(gtf) from ch_gtf

    output:
    set val(sample), file("${sample}_arriba.tsv") optional true into arriba_fusions_summary
    set val(sample), file("${sample}_arriba.bam"), file("${sample}_arriba.tsv") optional true into arriba_visualization
    file("*.{tsv,txt}") into arriba_output

    script:
    def extra_params = params.arriba_opt ? "${params.arriba_opt}" : ''
    """
    STAR \\
        --genomeDir ${star_index} \\
        --runThreadN ${task.cpus} \\
        --readFilesIn ${reads} \\
        --outStd BAM_Unsorted \\
        --outSAMtype BAM Unsorted \\
        --outSAMunmapped Within \\
        --outBAMcompression 0 \\
        --outFilterMultimapNmax 1 \\
        --outFilterMismatchNmax 3 \\
        --chimSegmentMin 10 \\
        --chimOutType WithinBAM SoftClip \\
        --chimJunctionOverhangMin 10 \\
        --chimScoreMin 1 \\
        --chimScoreDropMax 30 \\
        --chimScoreJunctionNonGTAG 0 \\
        --chimScoreSeparation 1 \\
        --alignSJstitchMismatchNmax 5 -1 5 5 \\
        --chimSegmentReadGapMax 3 \\
        --readFilesCommand zcat \\
        --sjdbOverhang ${params.read_length - 1} |
    
    tee Aligned.out.bam |

    arriba \\
        -x /dev/stdin \\
        -a ${fasta} \\
        -g ${gtf} \\
        -b ${reference}/blacklist_hg38_GRCh38_2018-11-04.tsv \\
        -o ${sample}_arriba.tsv -O ${sample}_discarded_arriba.tsv \\
        -T -P \\
        ${extra_params}

    mv Aligned.out.bam ${sample}_arriba.bam
    """
}

arriba_fusions_summary = arriba_fusions_summary.dump(tag:'arriba_fusions_summary')

/*
 * STAR-Fusion
 */
process star_fusion {
    tag {sample}

    publishDir "${params.outdir}/tools/Star-Fusion/${sample}", mode: 'copy'

    when:
    params.star_fusion || (params.star_fusion && params.debug)

    input:
    set val(sample), file(reads) from read_files_star_fusion
    file(reference) from reference.star_fusion
    file(star_index) from ch_star_index

    output:
    set val(sample), file("${sample}_star-fusion.tsv") optional true into star_fusion_fusions
    file("*.{tsv,txt}") into star_fusion_output

    script:
    def avail_mem = task.memory ? "--limitBAMsortRAM ${task.memory.toBytes() - 100000000}" : ''
    option = params.singleEnd ? "--left_fq ${reads[0]}" : "--left_fq ${reads[0]} --right_fq ${reads[1]}"
    def extra_params = params.star_fusion_opt ? "${params.star_fusion_opt}" : ''
    """
    STAR \\
        --genomeDir ${star_index} \\
        --readFilesIn ${reads} \\
        --twopassMode Basic \\
        --outReadsUnmapped None \\
        --chimSegmentMin 12 \\
        --chimJunctionOverhangMin 12 \\
        --alignSJDBoverhangMin 10 \\
        --alignMatesGapMax 100000 \\
        --alignIntronMax 100000 \\
        --chimSegmentReadGapMax 3 \\
        --alignSJstitchMismatchNmax 5 -1 5 5 \\
        --runThreadN ${task.cpus} \\
        --outSAMstrandField intronMotif ${avail_mem} \\
        --outSAMunmapped Within \\
        --outSAMtype BAM Unsorted \\
        --outSAMattrRGline ID:GRPundef \\
        --chimMultimapScoreRange 10 \\
        --chimMultimapNmax 10 \\
        --chimNonchimScoreDropMin 10 \\
        --peOverlapNbasesMin 12 \\
        --peOverlapMMp 0.1 \\
        --readFilesCommand zcat \\
        --sjdbOverhang ${params.read_length - 1} \\
        --chimOutJunctionFormat 1

    STAR-Fusion \\
        --genome_lib_dir ${reference} \\
        -J Chimeric.out.junction \\
        ${option} \\
        --CPU ${task.cpus} \\
        --examine_coding_effect \\
        --output_dir . ${extra_params}

    mv star-fusion.fusion_predictions.tsv ${sample}_star-fusion.tsv
    """
}

star_fusion_fusions = star_fusion_fusions.dump(tag:'star_fusion_fusions')

/*
 * Fusioncatcher
 */
process fusioncatcher {
    tag {sample}

    publishDir "${params.outdir}/tools/Fusioncatcher/${sample}", mode: 'copy'

    when:
    params.fusioncatcher || (params.fusioncatcher && params.debug)

    input:
    set val(sample), file(reads) from read_files_fusioncatcher
    file(data_dir) from reference.fusioncatcher

    output:
    set val(sample), file("${sample}_fusioncatcher.txt") optional true into fusioncatcher_fusions
    file("*.{txt,zip,log}") into fusioncatcher_output

    script:
    option = params.singleEnd ? reads[0] : "${reads[0]},${reads[1]}"
    def extra_params = params.fusioncatcher_opt ? "${params.fusioncatcher_opt}" : ''
    """
    fusioncatcher \\
        -d ${data_dir} \\
        -i ${option} \\
        --threads ${task.cpus} \\
        -o . \\
        --skip-blat ${extra_params}

    mv final-list_candidate-fusion-genes.txt ${sample}_fusioncatcher.txt
    """
}

fusioncatcher_fusions = fusioncatcher_fusions.dump(tag:'fusioncatcher_fusions')

/*
 * Ericscript
 */
process ericscript {
    tag {sample}

    publishDir "${params.outdir}/tools/EricScript/${sample}", mode: 'copy'

    when:
    params.ericscript && (!params.singleEnd || params.debug)

    input:
    set val(sample), file(reads) from read_files_ericscript
    file(reference) from reference.ericscript

    output:
    set val(sample), file("./tmp/${sample}_ericscript.tsv") optional true into ericscript_fusions
    file("./tmp/fusions.results.total.tsv") optional true into ericscript_output

    script:
    """
    ericscript.pl \\
        -db ${reference} \\
        -name fusions \\
        -p ${task.cpus} \\
        -o ./tmp \\
        ${reads}

    mv fusions.results.filtered.tsv ${sample}_ericscript.tsv
    """
}

ericscript_fusions = ericscript_fusions.dump(tag:'ericscript_fusions')

/*
 * Pizzly
 */
process pizzly {
    tag {sample}

    publishDir "${params.outdir}/tools/Pizzly/${sample}", mode: 'copy'

    when:
    params.pizzly && (!params.singleEnd || params.debug)

    input:
    set val(sample), file(reads) from read_files_pizzly
    file(gtf) from ch_gtf
    file(transcript) from ch_transcript
    
    output:
    set val(sample), file("${sample}_pizzly.txt") optional true into pizzly_fusions
    file("*.{json,txt}") into pizzly_output

    script:
    """
    kallisto index -i index.idx -k ${params.pizzly_k} ${transcript}
    kallisto quant -t ${task.cpus} -i index.idx --fusion -o output ${reads[0]} ${reads[1]}
    pizzly -k ${params.pizzly_k} \\
        --gtf ${gtf} \\
        --cache index.cache.txt \\
        --align-score 2 \\
        --insert-size 400 \\
        --fasta ${transcript} \\
        --output pizzly_fusions output/fusion.txt
    pizzly_flatten_json.py pizzly_fusions.json pizzly_fusions.txt

    mv index.cache.txt ${sample}_pizzly_cache.txt
    mv pizzly_fusions.json ${sample}_pizzly.txt
    mv pizzly_fusions.txt ${sample}_pizzly.txt
    mv pizzly_fusions.unfiltered.json ${sample}_unfiltered_pizzly.json
    """
}

pizzly_fusions = pizzly_fusions.dump(tag:'pizzly_fusions')

/*
 * Squid
 */
process squid {
    tag {sample}

    publishDir "${params.outdir}/tools/Squid/${sample}", mode: 'copy'

    when:
    params.squid && (!params.singleEnd || params.debug)

    input:
    set val(sample), file(reads) from read_files_squid
    file(star_index) from ch_star_index
    file(gtf) from ch_gtf
    
    output:
    set val(sample), file("${sample}_fusions_annotated.txt") optional true into squid_fusions
    file("*.txt") into squid_output

    script:
    def avail_mem = task.memory ? "--limitBAMsortRAM ${task.memory.toBytes() - 100000000}" : ''
    """
    STAR \\
        --genomeDir ${star_index} \\
        --sjdbGTFfile ${gtf} \\
        --runThreadN ${task.cpus} \\
        --readFilesIn ${reads} \\
        --twopassMode Basic \\
        --chimOutType SeparateSAMold --chimSegmentMin 20 --chimJunctionOverhangMin 12 --alignSJDBoverhangMin 10 --outReadsUnmapped Fastx --outSAMstrandField intronMotif \\
        --outSAMtype BAM SortedByCoordinate ${avail_mem} \\
        --readFilesCommand zcat
    mv Aligned.sortedByCoord.out.bam ${sample}Aligned.sortedByCoord.out.bam
    samtools view -bS Chimeric.out.sam > ${sample}Chimeric.out.bam
    squid -b ${sample}Aligned.sortedByCoord.out.bam -c ${sample}Chimeric.out.bam -o fusions
    AnnotateSQUIDOutput.py ${gtf} fusions_sv.txt fusions_annotated.txt

    mv fusions_annotated.txt ${sample}_fusions_annotated.txt
    """
}

squid_fusions = squid_fusions.dump(tag:'squid_fusions')

read_files_summary = read_files_summary.dump(tag:'read_files_summary')

files_and_reports_summary = read_files_summary
    .join(arriba_fusions_summary, remainder: true)
    .join(ericscript_fusions, remainder: true)
    .join(fusioncatcher_fusions, remainder: true)
    .join(pizzly_fusions, remainder: true)
    .join(squid_fusions, remainder: true)
    .join(star_fusion_fusions, remainder: true)

files_and_reports_summary = files_and_reports_summary.dump(tag:'files_and_reports_summary')

/*
================================================================================
                               SUMMARIZING RESULTS
================================================================================
*/

process summary {
    tag {sample}

    publishDir "${params.outdir}/Reports/${sample}", mode: 'copy'
 
    when:
    !params.debug && (params.arriba || params.fusioncatcher || params.star_fusion || params.ericscript || params.pizzly || params.squid)
    
    input:
    set val(sample), file(reads), file(arriba), file(ericscript), file(fusioncatcher), file(pizzly), file(squid), file(starfusion) from files_and_reports_summary

    output:
    file("${sample}_fusion_list.tsv") into fusion_inspector_input_list
    file("${sample}_fusion_genes_mqc.json") into summary_fusions_mq
    file("*") into report
    
    script:
    def extra_params = params.fusion_report_opt ? "${params.fusion_report_opt}" : ''
    def tools = !arriba.empty() ? "--arriba ${arriba} " : ''
    tools += !ericscript.empty() ? "--ericscript ${ericscript} " : ''
    tools += !fusioncatcher.empty() ? "--fusioncatcher ${fusioncatcher} " : ''
    tools += !pizzly.empty() ? "--pizzly ${pizzly} " : ''
    tools += !squid.empty() ? "--squid ${squid} " : ''
    tools += !starfusion.empty() ? "--starfusion ${starfusion} " : ''
    """
    fusion_report run ${sample} . ${params.databases} \\
        ${tools} ${extra_params}
    mv fusion_list.tsv ${sample}_fusion_list.tsv
    mv fusion_genes_mqc.json ${sample}_fusion_genes_mqc.json
    """
}

/*************************************************************
 * Visualization
 ************************************************************/

/*
 * Arriba Visualization
 */
process arriba_visualization {
    tag {sample}

    publishDir "${params.outdir}/tools/Arriba/${sample}", mode: 'copy'

    when:
    params.arriba_vis && (!params.singleEnd || params.debug)

    input:
    file(reference) from reference.arriba_vis
    set sample, file(bam), file(fusions) from arriba_visualization
    file(gtf) from ch_gtf

    output:
    file("${sample}.pdf") optional true into arriba_visualization_output

    script:
    def suff_mem = ("${(task.memory.toBytes() - 6000000000) / task.cpus}" > 2000000000) ? 'true' : 'false'
    def avail_mem = (task.memory && suff_mem) ? "-m" + "${(task.memory.toBytes() - 6000000000) / task.cpus}" : ''
    """
    samtools sort -@ ${task.cpus} ${avail_mem} -O bam ${bam} > Aligned.sortedByCoord.out.bam
    samtools index Aligned.sortedByCoord.out.bam
    draw_fusions.R \\
        --fusions=${fusions} \\
        --alignments=Aligned.sortedByCoord.out.bam \\
        --output=${sample}.pdf \\
        --annotation=${gtf} \\
        --cytobands=${reference}/cytobands_hg38_GRCh38_2018-02-23.tsv \\
        --proteinDomains=${reference}/protein_domains_hg38_GRCh38_2018-03-06.gff3
    """
}

/*
 * Fusion Inspector
 */
process fusion_inspector {
    tag {sample}

    publishDir "${params.outdir}/tools/FusionInspector/${sample}", mode: 'copy'

    when:
    params.fusion_inspector && (!params.singleEnd || params.debug)

    input:
    set val(sample), file(reads) from read_files_fusion_inspector
    file(reference) from reference.fusion_inspector
    file(fi_input_list) from fusion_inspector_input_list.collect()

    output:
    file("*.{fa,gtf,bed,bam,bai,txt}") into fusion_inspector_output

    script:
    def extra_params = params.fusion_inspector_opt ? "${params.fusion_inspector_opt}" : ''
    """
    FusionInspector \\
        --fusions ${fi_input_list} \\
        --genome_lib ${reference} \\
        --left_fq ${reads[0]} \\
        --right_fq ${reads[1]} \\
        --CPU ${task.cpus} \\
        --out_dir . \\
        --out_prefix finspector \\
        --vis ${extra_params} 
    """
}

/*************************************************************
 * Quality check & software verions
 ************************************************************/

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
    saveAs: {filename ->
        if (filename.indexOf(".csv") > 0) filename
        else null
    }

    when:
    !params.debug

    output:
    file('software_versions_mqc.yaml') into software_versions_yaml
    file('software_versions.csv')

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    cat $baseDir/tools/arriba/environment.yml > v_arriba.txt
    cat $baseDir/tools/fusioncatcher/environment.yml > v_fusioncatcher.txt
    cat $baseDir/tools/fusion-inspector/environment.yml > v_fusion_inspector.txt
    cat $baseDir/tools/star-fusion/environment.yml > v_star_fusion.txt
    cat $baseDir/tools/ericscript/environment.yml > v_ericscript.txt
    cat $baseDir/tools/pizzly/environment.yml > v_pizzly.txt
    cat $baseDir/tools/squid/environment.yml > v_squid.txt
    cat $baseDir/environment.yml > v_fusion_report.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * FastQC
 */
process fastqc {
    tag "$name"
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

    when:
    !params.debug

    input:
    set val(name), file(reads) from read_files_fastqc

    output:
    file("*_fastqc.{zip,html}") into fastqc_results

    script:
    """
    fastqc -q $reads
    """
}

/*
 * MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    when:
    !params.debug

    input:
    file(multiqc_config) from ch_multiqc_config
    file("fastqc/*") from fastqc_results.collect().ifEmpty([])
    file("software_versions/*") from software_versions_yaml.collect()
    file(workflow_summary) from create_workflow_summary(summary)
    file(fusions_mq) from summary_fusions_mq.collect().ifEmpty([])

    output:
    file("*multiqc_report.html") into multiqc_report
    file("*_data")
    file("multiqc_plots")

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config .
    """
}

/*
 * Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    when:
    !params.debug

    input:
    file(output_docs) from ch_output_docs

    output:
    file("results_description.html")

    script:
    """
    markdown_to_html.r ${output_docs} results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/rnafusion] Successful: $workflow.runName"
    if(!workflow.success) {
      subject = "[nf-core/rnafusion] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/rnafusion] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/rnafusion] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ) { throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/rnafusion] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/rnafusion] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCountFmt > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCountFmt} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCountFmt} ${c_reset}"
    }

    if(workflow.success) {
        log.info "${c_purple}[nf-core/rnafusion]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/rnafusion]${c_red} Pipeline completed with errors${c_reset}"
    }

}

def nfcoreHeader() {
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/rnafusion v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
