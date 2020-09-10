#!/usr/bin/env nextflow

process bwa_index_reference{
  cpus 1

  output:
  file "database.rdy" into bwa_indexes

  """
  if [ ! -f "${params.reference}.sa" ]; then
    bwa index ${params.reference}
  fi
  touch database.rdy
  """
}

process kraken2_db_download{
  cpus 1

  output:
  file 'database.rdy' into kraken2_init

  """
  if ${params.kraken_db_download} ; then
    wd=\$(pwd)
    export PATH=\$PATH:$baseDir/bin/
    mkdir -p ${params.krakendb}
    cd ${params.krakendb} && wget ${params.krakendb_url} -O krakendb.tgz
    dlsuf=`tar -tf krakendb.tgz | head -n 1 | tail -c 2`
    if [ -f "${params.reference}.sa" ]; then
      tar -xvzf krakendb.tgz --strip 1
    else
      tar -xvzf krakendb.tgz
    fi
    rm krakendb.tgz
    cd \${wd} && touch database.rdy
  else
    cd \${wd} && touch database.rdy
  fi
  """
}

process ariba_db_download{

  output:
  file 'database.rdy' into ariba_init

  """
  if  ${params.ariba_db_download} ; then
    ariba getref resfinder resfinder
    ariba prepareref --force -f ./resfinder.fa -m ./resfinder.tsv --threads ${task.cpus} ${params.aribadb}
    mv resfinder.fa ${params.aribadb}
    mv resfinder.tsv ${params.aribadb}
    touch database.rdy
  else
    touch database.rdy
  fi
  """

}

samples = Channel.fromPath("${params.input}/*.{fastq.gz,fsa.gz,fa.gz,fastq,fsa,fa}")

process fastqc_readqc{
  publishDir "${params.outdir}/fastqc", mode: 'copy', overwrite: true

  input:
  file lane1dir from samples

  output:
  file "*_fastqc.html" into fastqc_results

  """
  fastqc ${params.input}/${lane1dir} --format fastq --threads ${task.cpus} -o .
  """
}

forward = Channel.fromPath("${params.input}/*1*.{fastq.gz,fsa.gz,fa.gz,fastq,fsa,fa}")
reverse = Channel.fromPath("${params.input}/*2*.{fastq.gz,fsa.gz,fa.gz,fastq,fsa,fa}")
 

process lane_concatination{
  publishDir "${params.outdir}/concatinated", mode: 'copy', overwrite: true
  cpus 1

  input:
  file 'forward_concat.fastq.gz' from forward.collectFile() 
  file 'reverse_concat.fastq.gz' from reverse.collectFile()

  output:
  tuple 'forward_concat.fastq.gz', 'reverse_concat.fastq.gz' into lane_concat

  """
  #Concatination is done via process flow
  """
}

process trimmomatic_trimming{
  publishDir "${params.outdir}/trimmomatic", mode: 'copy', overwrite: true

  input:
  tuple forward, reverse from lane_concat

  output:
  tuple "trim_front_pair.fastq.gz", "trim_rev_pair.fastq.gz", "trim_unpair.fastq.gz" into (trimmed_sample_1, trimmed_sample_2, trimmed_sample_3, trimmed_sample_4)
  
  """
  trimmomatic PE -threads ${task.cpus} -phred33 ${forward} ${reverse} trim_front_pair.fastq.gz trim_front_unpair.fastq.gz  trim_rev_pair.fastq.gz trim_rev_unpair.fastq.gz ILLUMINACLIP:${params.adapters}:2:30:10 LEADING:3 TRAILING:3 SLIDINGWINDOW:4:15 MINLEN:36
  cat trim_front_unpair.fastq.gz trim_rev_unpair.fastq.gz >> trim_unpair.fastq.gz
  """

}

process ariba_resistancefind{
  publishDir "${params.outdir}/ariba", mode: 'copy', overwrite: true

  input:
  tuple forward, reverse, unpaired from trimmed_sample_4 
  file(database_initalization) from ariba_init 

  output:
  file 'ariba/motif_report.tsv' into ariba_output
  

  """
  ariba run --spades_options careful --force --threads ${task.cpus} ${params.aribadb} ${forward} ${reverse} \$(pwd)/ariba
  mv \$(pwd)/ariba/report.tsv \$(pwd)/ariba/motif_report.tsv
  """
}

process ariba_stats{
  publishDir "${params.outdir}/ariba", mode: 'copy', overwrite: true
  cpus 1

  input:
  file(report) from ariba_output

  output:
  file 'summary.csv' into ariba_summary_output 

  """
  ariba summary --col_filter n --row_filter n summary ${report}
  """
}

process kraken2_decontamination{
  publishDir "${params.outdir}/kraken2", mode: 'copy', overwrite: true

  input:
  tuple forward, reverse, unpaired from trimmed_sample_3
  file(db_initialized) from kraken2_init


  output:
  tuple "kraken_out.tsv", "kraken_report.tsv" into kraken2_output


  """
  kraken2 --db ${params.krakendb} --threads ${task.cpus} --output kraken_out.tsv --report kraken_report.tsv --paired ${forward} ${reverse}
  """    
}
process spades_assembly{
  publishDir "${params.outdir}/spades", mode: 'copy', overwrite: true

  input:
  file(reads) from trimmed_sample_1

  output:
  file 'scaffolds.fasta' into (assembled_sample_1, assembled_sample_2)

  script:
  """
  spades.py --threads ${task.cpus} --careful -o . -1 ${reads[0]} -2 ${reads[1]} -s ${reads[2]}
  """
}

process mlst_lookup{
  publishDir "${params.outdir}/mlst", mode: 'copy', overwrite: true

  input:
  file contig from assembled_sample_1


  """
  mlst $contig --threads ${task.cpus} --json mlst.json --novel novel_mlst.fasta --minid 99.5 --mincov 95
  """
}

process quast_assembly_qc{
  publishDir "${params.outdir}/quast", mode: 'copy', overwrite: true

  input:
  file contig from assembled_sample_2

  output:
  file 'quast_report.tsv' into quast_result, quast_result_2

  """
  quast.py $contig -o . -r ${params.reference} -t ${task.cpus}
  cp report.tsv quast_report.tsv
  
  """
}

process quast_json_conversion{
  publishDir "${params.outdir}/quast", mode: 'copy', overwrite: true
  cpus 1

  input:
  file(quastreport) from quast_result_2

  output:
  file 'quast_report.json' into quast_result_json

  """
  python $baseDir/bin/quast_report_to_json.py $quastreport quast_report.json
  """
}


process bwa_read_mapping{
  publishDir "${params.outdir}/bwa", mode: 'copy', overwrite: true

  input:
  file(trimmed) from trimmed_sample_2
  file(database_initalization) from bwa_indexes

  output:
  file 'alignment.sam' into mapped_sample

  """
  bwa mem -M -t ${task.cpus} ${params.reference} ${trimmed[0]} ${trimmed[1]} > alignment.sam
  """
}

process samtools_bam_conversion{
  publishDir "${params.outdir}/bwa", mode: 'copy', overwrite: true

  input:
  file(aligned_sam) from mapped_sample

  output:
  file 'alignment_sorted.bam' into sorted_sample_1, sorted_sample_2

  """
  samtools view --threads ${task.cpus} -b -o alignment.bam -T ${params.reference} ${aligned_sam}
  samtools sort --threads ${task.cpus} -o alignment_sorted.bam alignment.bam
  

  """
}

process samtools_duplicates_stats{
  publishDir "${params.outdir}/samtools", mode: 'copy', overwrite: true

  input:
  file(align_sorted) from sorted_sample_1

  output:
  tuple 'samtools_flagstats.txt', 'samtools_total_reads.txt' into samtools_duplicated_results

  """
  samtools flagstat ${align_sorted} &> samtools_flagstats.txt
  samtools view -c ${align_sorted} &> samtools_total_reads.txt
  """
}

process picard_markduplicates{
  publishDir "${params.outdir}/picard", mode: 'copy', overwrite: true
  cpus 1

  input:
  file(align_sorted) from sorted_sample_2

  output:
  file 'alignment_sorted_rmdup.bam' into deduplicated_sample, deduplicated_sample_2, deduplicated_sample_3
  file 'picard_duplication_stats.txt' into picard_histogram_output

  """
  picard MarkDuplicates I=${align_sorted} O=alignment_sorted_rmdup.bam M=picard_duplication_stats.txt REMOVE_DUPLICATES=true
  """
}

process samtools_calling{
  publishDir "${params.outdir}/snpcalling", mode: 'copy', overwrite: true

  input:
  file(align_sorted_rmdup) from deduplicated_sample

  output:
  file 'samtools_calls.bam' into called_sample

  """
  samtools view -@ ${task.cpus} -h -q 1 -F 4 -F 256 ${align_sorted_rmdup} | grep -v XA:Z | grep -v SA:Z| samtools view -b - > samtools_calls.bam
  """
}


process vcftools_snpcalling{
  publishDir "${params.outdir}/snpcalling", mode: 'copy', overwrite: true
  cpus 1

  input:
  file(samhits) from called_sample

  output:
  file 'vcftools.recode.bcf' into snpcalling_output

  """
  vcffilter="--minQ 30 --thin 50 --minDP 3 --min-meanDP 20"
  bcffilter="GL[0]<-500 & GL[1]=0 & QR/RO>30 & QA/AO>30 & QUAL>5000 & ODDS>1100 & GQ>140 & DP>100 & MQM>59 & SAP<15 & PAIRED>0.9 & EPP>3"
 
  
  freebayes -= --pvar 0.7 -j -J --standard-filters -C 6 --min-coverage 30 --ploidy 1 -f ${params.reference} -b ${samhits} -v freebayes.vcf
  bcftools view freebayes.vcf -o unfiltered_bcftools.bcf.gz -O b --exclude-uncalled --types snps
  bcftools index unfiltered_bcftools.bcf.gz
  bcftools view unfiltered_bcftools.bcf.gz -i \${bcffilter} -o bcftools.bcf.gz -O b
  vcftools --bcf bcftools.bcf.gz \${vcffilter} --remove-filtered-all --recode-INFO-all --recode-bcf --out vcftools

  """
}
                   	

process picard_qcstats{
  publishDir "${params.outdir}/picard", mode: 'copy', overwrite: true
  cpus 1

  input:
  file(alignment_sorted_rmdup) from deduplicated_sample_2
  
  output:
  tuple 'picard_stats.txt', 'picard_insert_distribution.pdf' into picard_output

  """
  picard CollectInsertSizeMetrics I=${alignment_sorted_rmdup} O=picard_stats.txt H=picard_insert_distribution.pdf

  """
}

process samtools_deduplicated_stats{
  publishDir "${params.outdir}/samtools", mode: 'copy', overwrite: true

  input:  
  file(alignment_sorted_rmdup) from deduplicated_sample_3

  output:
  tuple 'samtools_idxstats.tsv', 'samtools_coverage_distribution.tsv' into samtools_deduplicated_output

  """
  samtools index ${alignment_sorted_rmdup}
  samtools idxstats ${alignment_sorted_rmdup} &> samtools_idxstats.tsv
  samtools stats --coverage 1,10000,1 ${alignment_sorted_rmdup} |grep ^COV | cut -f 2- &> samtools_coverage_distribution.tsv

  """

}

/*
The following reports are generated ( * = Supported in multiqc):

Ariba summary
* Kraken report
MLST report, MLST novel
* Picard Insert Size
* Picard MarkDuplicates
* Quast report
Quast json
* Samtools flagstat
* Samtools idxstats
Samtools coverage distribution
Samtools total reads
SNPcalling

*/
process multiqc_report{
  publishDir "${params.outdir}/multiqc", mode: 'copy', overwrite: true
  cpus 1

  //More inputs as tracks are added
  input:
  file(quast_report) from quast_result
  file(fastqc_report) from fastqc_results
  tuple picard_stats, picard_insert_stats from picard_output
  tuple kraken_output, kraken_report from kraken2_output 
  tuple samtools_map, samtools_raw from samtools_duplicated_results
  
  output:
  file 'multiqc/multiqc_report.html' into multiqc_output

  """
  multiqc ${params.outdir} -f -o \$(pwd)/multiqc
  """
}
